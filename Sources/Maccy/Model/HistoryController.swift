import AppKit
import MaccyCore
import Observation
import UniformTypeIdentifiers

/// Connects the store, the pasteboard monitor and the UI. It owns all actions
/// on history items (paste, copy, pin, delete, …).
@Observable
final class HistoryController {
  let preferences: Preferences
  @ObservationIgnored let store: HistoryStore
  @ObservationIgnored private(set) var monitor: ClipboardMonitor!
  @ObservationIgnored private let writer: PasteboardWriter
  @ObservationIgnored private var pruneTask: Task<Void, Never>?
  @ObservationIgnored private var latestCaptureDate = Date.distantPast

  /// Increments after each change to the stored history. Views refresh on change.
  private(set) var revision = 0
  /// The title of the most recent item, for the menu bar. Masked for a secret.
  private(set) var latestTitle: String?
  /// The menu bar is visible in screen shares and screenshots, so it never shows a secret.
  static let hiddenTitle = "••••••"
  /// A short message for the panel footer.
  var toast: String?

  /// Counters for the self-test, which waits for the capture pipeline.
  @ObservationIgnored private(set) var processedCaptures = 0
  @ObservationIgnored private(set) var processedOCR = 0

  /// Called after an action that must close the panel (paste, copy).
  @ObservationIgnored var closePanel: () -> Void = {}
  /// The system Accessibility prompt shows once per launch, not at each ↩.
  @ObservationIgnored private var didRequestAccess = false

  init(
    preferences: Preferences,
    store: HistoryStore,
    pasteboard: NSPasteboard = .general,
    defaults: UserDefaults = .standard
  ) {
    self.preferences = preferences
    self.store = store
    self.writer = PasteboardWriter(pasteboard: pasteboard)
    // Weak: the controller owns the monitor, and the monitor owns this closure.
    self.monitor = ClipboardMonitor(pasteboard: pasteboard, defaults: defaults) { [store, weak self] clip, rules in
      Task {
        let outcome = await Self.ingest(clip, rules: rules, store: store)
        await MainActor.run {
          if let outcome {
            self?.didIngest(outcome)
          }
          self?.processedCaptures += 1
        }
        if let image = outcome?.imageForOCR, let id = outcome?.result.id {
          await Self.recognizeText(in: image, id: id, store: store)
          await MainActor.run {
            self?.revision += 1
            self?.processedOCR += 1
          }
        }
      }
    }
    // Every write by Maccy (paste-back, edited text, clear) is skipped by the monitor.
    writer.didWrite = { [monitor] changeCount in monitor?.markOwnChange(changeCount) }
  }

  func start() {
    monitor.update(rules: CaptureRules(preferences: preferences))
    monitor.start(interval: preferences.pollInterval)
    Task {
      await refreshLatestTitle()
      await prune()
      if let removed = try? await store.collectGarbage(), removed > 0 {
        Log.history.info("Removed \(removed) unreferenced blob files")
      }
    }
    scheduleRetention()
  }

  // MARK: - Ingest (off the main actor)

  struct IngestOutcome: Sendable {
    var result: UpsertResult
    var title: String
    var isSensitive: Bool
    var capturedAt: Date
    var expiresAt: Date?
    var imageForOCR: Data?
  }

  nonisolated static func ingest(_ clip: CapturedClip, rules: CaptureRules, store: HistoryStore) async -> IngestOutcome? {
    guard let analyzed = ClipAnalyzer.analyze(clip) else {
      return nil
    }
    var expiresAt: Date?
    if let secret = analyzed.detectedSecret, let lifetime = rules.secretLifetime {
      guard lifetime > 0 else {
        Log.capture.info("Did not save a copy that matches the rule '\(secret, privacy: .public)'")
        return nil
      }
      expiresAt = analyzed.capturedAt.addingTimeInterval(lifetime)
    }
    let thumbnail = analyzed.primaryImage.flatMap { ImageProcessing.thumbnailPNG(from: $0, maxPixelSize: 96) }
    do {
      let result = try await store.upsert(analyzed, thumbnail: thumbnail, expiresAt: expiresAt)
      let wantsOCR = rules.ocrEnabled && result.isNew && analyzed.kind == .image
      return IngestOutcome(
        result: result,
        title: analyzed.title,
        isSensitive: analyzed.detectedSecret != nil,
        capturedAt: analyzed.capturedAt,
        expiresAt: expiresAt,
        imageForOCR: wantsOCR ? analyzed.primaryImage : nil
      )
    } catch {
      Log.history.error("Cannot save a copy: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  nonisolated static func recognizeText(in image: Data, id: Int64, store: HistoryStore) async {
    guard let text = await TextRecognizer.recognizeText(in: image) else {
      return
    }
    try? await store.setOCRText(id: id, text: text)
  }

  private func didIngest(_ outcome: IngestOutcome) {
    // Ingest tasks can finish out of order. Keep the title of the newest copy.
    if outcome.capturedAt >= latestCaptureDate {
      latestCaptureDate = outcome.capturedAt
      latestTitle = outcome.isSensitive ? Self.hiddenTitle : outcome.title
    }
    revision += 1
    if outcome.expiresAt != nil {
      scheduleRetention()
    }
  }

  // MARK: - Retention

  /// Prunes now, then again at the next expiry or in one hour, whichever is first.
  func scheduleRetention() {
    pruneTask?.cancel()
    let store = store
    // The loop holds `self` only for the prune, not during the sleep of up to an hour.
    pruneTask = Task { [weak self] in
      while !Task.isCancelled {
        let nextExpiry = try? await store.nextExpiry()
        let hour = Date.now.addingTimeInterval(3_600)
        let wake = min(nextExpiry ?? hour, hour)
        let delay = max(1, wake.timeIntervalSinceNow)
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, let self else {
          return
        }
        // An unstructured task: a later reschedule must not interrupt a running prune.
        await Task { await self.prune() }.value
      }
    }
  }

  func prune() async {
    do {
      let deleted = try await store.prune(policy: preferences.retentionPolicy)
      if deleted > 0 {
        Log.history.info("Pruned \(deleted) items")
        revision += 1
        await refreshLatestTitle()
      }
    } catch {
      Log.history.error("Prune failed: \(String(describing: error), privacy: .public)")
    }
  }

  private func refreshLatestTitle() async {
    latestTitle = (try? await store.latestUnpinned()).map { $0.isSensitive ? Self.hiddenTitle : $0.title }
  }

  // MARK: - Actions

  enum Delivery {
    case paste
    case copy
  }

  /// The action for ↩. ⌘↩ does the other one.
  var primaryDelivery: Delivery { preferences.pasteAutomatically ? .paste : .copy }
  var secondaryDelivery: Delivery { preferences.pasteAutomatically ? .copy : .paste }

  func deliver(_ id: Int64, as delivery: Delivery, plainText: Bool? = nil) async {
    let plainTextOnly = plainText ?? preferences.pastePlainTextByDefault
    do {
      let representations = try await store.representations(id: id)
      let detailText = plainTextOnly ? try await store.detail(id: id)?.text : nil
      guard !representations.isEmpty else {
        toast = "The item has no data."
        return
      }
      writer.write(representations, plainText: detailText, plainTextOnly: plainTextOnly)
    } catch {
      Log.history.error("Cannot deliver an item: \(String(describing: error), privacy: .public)")
      toast = "Cannot read the item."
      return
    }
    // Close and paste first. Moving the item to the top can wait.
    finish(delivery)
    try? await store.touch(id: id)
    revision += 1
    await refreshLatestTitle()
  }

  /// Pastes or copies text that is not in the history (edited text, a search string).
  func deliver(text: String, as delivery: Delivery) {
    writer.write(string: text)
    finish(delivery)
  }

  private func finish(_ delivery: Delivery) {
    if delivery == .paste && !Paster.isTrusted {
      // The copy succeeded, but the paste needs Accessibility. Keep the panel open, so
      // the message shows: after the close, the next open clears it. The first time,
      // the system prompt explains the problem (it takes the focus and closes the panel).
      toast = "Copied. Allow Accessibility access to paste automatically."
      if !didRequestAccess {
        didRequestAccess = true
        Paster.requestAccess()
      }
      return
    }
    closePanel()
    guard delivery == .paste else {
      return
    }
    // Let the target app become key again before the keystroke arrives.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      Paster.paste()
    }
  }

  func setPinned(_ id: Int64, _ pinned: Bool) async {
    try? await store.setPinned(id: id, pinned)
    revision += 1
  }

  func delete(_ ids: [Int64]) async {
    _ = try? await store.delete(ids: ids)
    revision += 1
    await refreshLatestTitle()
  }

  func clearHistory(keepPinned: Bool) async {
    _ = try? await store.deleteAll(keepPinned: keepPinned)
    if preferences.clearSystemClipboard {
      writer.clear()
    }
    revision += 1
    latestTitle = nil
  }

  func copyText(_ text: String) {
    writer.write(string: text)
    toast = "Copied."
  }

  func open(_ url: URL) {
    closePanel()
    NSWorkspace.shared.open(url)
  }

  func revealInFinder(_ urls: [URL]) {
    closePanel()
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  func saveImage(_ id: Int64) async {
    guard let data = try? await store.imageData(id: id) else {
      toast = "Cannot read the image."
      return
    }
    let type = UTType(filenameExtension: "png") ?? .png
    let panel = NSSavePanel()
    panel.allowedContentTypes = [type]
    panel.nameFieldStringValue = "Clipboard Image.png"
    panel.level = .screenSaver + 1
    NSApp.activate()
    let response = panel.runModal()
    NSApp.returnFocusIfIdle()
    guard response == .OK, let url = panel.url else {
      return
    }
    let png = await Self.pngForSaving(data)
    do {
      try png.write(to: url, options: .atomic)
    } catch {
      // The save panel took the focus, so the clipboard panel is closed. A message in
      // its footer would not show. Use an alert.
      NSApp.activate()
      NSAlert(error: error).runModal()
      NSApp.returnFocusIfIdle()
    }
  }

  /// A stored PNG is written as it is. Another format needs a full decode, so the
  /// conversion runs off the main thread, with no pixel limit: the user asked for it.
  @concurrent
  nonisolated private static func pngForSaving(_ data: Data) async -> Data {
    if ImageProcessing.typeIdentifier(of: data) == PasteboardTypes.png {
      return data
    }
    return ImageProcessing.pngData(from: data, maxPixelCount: .max) ?? data
  }
}
