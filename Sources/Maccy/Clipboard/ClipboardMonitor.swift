import AppKit
import MaccyCore
import Synchronization

/// The application that was frontmost at the time of a copy.
nonisolated struct SourceApp: Sendable, Equatable {
  var bundleID: String?
  var name: String?
}

/// Watches the general pasteboard. macOS has no change notification for the
/// pasteboard, so a background timer compares `changeCount` (a cheap call that
/// reads no content). On a change, the monitor reads only the allowed types,
/// off the main thread, and hands a `CapturedClip` to `onCapture`.
nonisolated final class ClipboardMonitor: Sendable {
  // NSPasteboard and UserDefaults are thread-safe, but not marked Sendable.
  nonisolated(unsafe) private let pasteboard: NSPasteboard
  // Utility, not user-initiated: the poll runs four times a second, all day.
  private let queue = DispatchQueue(label: "com.pgilad.Maccy.capture", qos: .utility)
  private let state: Mutex<State>
  private let rules = Mutex(CaptureRules())
  private let sourceApp = Mutex<SourceApp?>(nil)
  nonisolated(unsafe) private let defaults: UserDefaults
  private let onCapture: @Sendable (CapturedClip, CaptureRules) -> Void

  private struct State {
    var timer: DispatchSourceTimer?
    var lastChangeCount: Int
    var ownChangeCounts: Set<Int> = []
  }

  init(
    pasteboard: NSPasteboard = .general,
    defaults: UserDefaults = .standard,
    onCapture: @escaping @Sendable (CapturedClip, CaptureRules) -> Void
  ) {
    self.pasteboard = pasteboard
    self.defaults = defaults
    self.onCapture = onCapture
    self.state = Mutex(State(lastChangeCount: pasteboard.changeCount))
  }

  func start(interval: TimeInterval) {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    // A leeway of a quarter of the interval lets macOS group the timer with other work.
    timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 250)))
    timer.setEventHandler { [weak self] in
      self?.poll()
    }
    state.withLock { state in
      state.timer?.cancel()
      state.timer = timer
    }
    timer.resume()
  }

  func stop() {
    state.withLock { state in
      state.timer?.cancel()
      state.timer = nil
    }
  }

  func update(rules newRules: CaptureRules) {
    rules.withLock { $0 = newRules }
  }

  func update(sourceApp app: SourceApp?) {
    sourceApp.withLock { $0 = app }
  }

  /// Maccy calls this after it writes to the pasteboard, so its own write is not captured.
  func markOwnChange(_ changeCount: Int) {
    _ = state.withLock { $0.ownChangeCounts.insert(changeCount) }
  }

  #if DEBUG
  /// Checks the pasteboard now, on the capture queue. Self-tests use this.
  func checkNow() async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.poll()
        continuation.resume()
      }
    }
  }
  #endif

  private func poll() {
    let changeCount = pasteboard.changeCount
    let isOwnChange: Bool? = state.withLock { state in
      guard changeCount != state.lastChangeCount else {
        return nil
      }
      state.lastChangeCount = changeCount
      return state.ownChangeCounts.remove(changeCount) != nil
    }
    guard let isOwnChange, !isOwnChange else {
      return
    }

    let rules = self.rules.withLock { $0 }
    // Cheap checks first. Only a real candidate may use up "skip next copy",
    // and a paused monitor reads no content at all.
    guard let candidate = preflight(rules: rules), !isPaused() else {
      return
    }
    guard let clip = read(candidate, rules: rules) else {
      return
    }
    // If the pasteboard changed while we read it, the items may not match the
    // checked types (for example a concealed password). The next poll handles it.
    guard pasteboard.changeCount == changeCount else {
      return
    }
    onCapture(clip, rules)
  }

  private func isPaused() -> Bool {
    if defaults.bool(forKey: Preferences.Key.ignoreEvents) {
      if defaults.bool(forKey: Preferences.Key.ignoreOnlyNextEvent) {
        defaults.set(false, forKey: Preferences.Key.ignoreEvents)
        defaults.set(false, forKey: Preferences.Key.ignoreOnlyNextEvent)
      }
      return true
    }
    let pauseUntil = defaults.double(forKey: Preferences.Key.pauseUntil)
    return pauseUntil > Date.now.timeIntervalSince1970
  }

  private struct Candidate {
    var allTypes: Set<String>
    var app: SourceApp?
  }

  /// Checks the type list and the source app. Reads no content.
  private func preflight(rules: CaptureRules) -> Candidate? {
    // `types` lists the types of all items. Check it first, so a concealed
    // password is never read at all.
    let allTypes = Set((pasteboard.types ?? []).map(\.rawValue))
    guard !allTypes.isEmpty,
          allTypes.isDisjoint(with: rules.ignoredTypes),
          !allTypes.contains(PasteboardTypes.fromMaccy) else {
      return nil
    }
    let app = sourceApp.withLock { $0 }
    if rules.isIgnored(bundleID: app?.bundleID) {
      return nil
    }
    return Candidate(allTypes: allTypes, app: app)
  }

  private func read(_ candidate: Candidate, rules: CaptureRules) -> CapturedClip? {
    let allTypes = candidate.allTypes
    let app = candidate.app
    var representations: [Representation] = []
    for (index, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
      let available = item.types.map(\.rawValue)
      // Check each item too: the item list is read after the type list.
      guard Set(available).isDisjoint(with: rules.ignoredTypes) else {
        return nil
      }
      for type in rules.typesToRead(from: available) {
        guard let data = item.data(forType: NSPasteboard.PasteboardType(type)), !data.isEmpty else {
          continue
        }
        guard data.count <= rules.sizeLimit(for: type) else {
          Log.capture.info("Skipped a large \(type, privacy: .public) representation (\(data.count) bytes)")
          continue
        }
        representations.append(Representation(itemIndex: index, type: type, data: data))
      }
    }

    let isUniversalClipboard = allTypes.contains(PasteboardTypes.universalClipboard)
    if isUniversalClipboard {
      representations = resolveUniversalClipboardImage(representations, rules: rules)
    }

    guard !representations.isEmpty else {
      return nil
    }

    if !rules.ignorePatterns.isEmpty, let text = ClipAnalyzer.plainText(in: representations) {
      switch rules.ignorePatterns.evaluate(text) {
      case .match:
        return nil
      case .timedOut:
        // The patterns are a privacy rule. A copy that they cannot check is not saved.
        Log.capture.info("Skipped a copy: the ignore patterns did not finish in time")
        return nil
      case .noMatch:
        break
      }
    }

    return CapturedClip(
      representations: representations,
      sourceBundleID: isUniversalClipboard ? nil : app?.bundleID,
      sourceAppName: isUniversalClipboard ? nil : app?.name,
      isUniversalClipboard: isUniversalClipboard,
      capturedAt: .now
    )
  }

  /// Universal Clipboard delivers a photo from an iPhone as a file URL to a
  /// temporary JPEG. Read the file now, because the system deletes it later.
  private func resolveUniversalClipboardImage(_ representations: [Representation], rules: CaptureRules) -> [Representation] {
    guard rules.saveImages,
          !representations.contains(where: { PasteboardTypes.images.contains($0.type) }),
          let fileURL = representations.first(where: { $0.type == PasteboardTypes.fileURL })
            .flatMap({ URL(dataRepresentation: $0.data, relativeTo: nil, isAbsolute: true) }),
          ["jpeg", "jpg", "heic", "png"].contains(fileURL.pathExtension.lowercased()),
          let data = try? Data(contentsOf: fileURL),
          data.count <= rules.maxImageBytes else {
      return representations
    }
    let type = switch fileURL.pathExtension.lowercased() {
    case "heic": PasteboardTypes.heic
    case "png": PasteboardTypes.png
    default: PasteboardTypes.jpeg
    }
    return representations.filter { $0.type != PasteboardTypes.fileURL } + [Representation(type: type, data: data)]
  }
}
