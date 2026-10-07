#if DEBUG
import AppKit
import MaccyCore
import SwiftUI

/// Renders the UI offscreen with sample data, to check layout without a screen recording.
@MainActor
enum SnapshotRenderer {
  static func render(to directory: URL) async -> Bool {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let dataDirectory = Diagnostics.temporaryDirectory("snapshots")
    defer { try? FileManager.default.removeItem(at: dataDirectory) }
    guard let store = try? HistoryStore(directory: dataDirectory) else {
      return false
    }
    let preferences = Preferences(defaults: Diagnostics.isolatedDefaults("snapshots"))
    await seed(store)

    let controller = HistoryController(
      preferences: preferences, store: store, pasteboard: NSPasteboard(name: .init("com.pgilad.Maccy.snapshots"))
    )
    let model = PanelModel(controller: controller)
    model.prepareForOpen(target: SourceApp(bundleID: "com.apple.dt.Xcode", name: "Xcode"))
    await settle(model)

    var ok = true
    ok = save(panel(model), size: preferences.windowSize, to: directory.appending(path: "panel-recent.png")) && ok

    if let image = model.rows.first(where: { $0.summary.kind == .image }) {
      model.selectedID = image.id
      await settle(model)
      ok = save(panel(model), size: preferences.windowSize, to: directory.appending(path: "panel-image.png")) && ok
    }

    if let color = model.rows.first(where: { $0.summary.kind == .color }) {
      model.selectedID = color.id
      await settle(model)
      ok = save(panel(model), size: preferences.windowSize, to: directory.appending(path: "panel-color.png")) && ok
    }

    model.query = "deploy"
    await settle(model)
    ok = save(panel(model), size: preferences.windowSize, to: directory.appending(path: "panel-search.png")) && ok

    model.isCommandHeld = true
    ok = save(panel(model), size: preferences.windowSize, to: directory.appending(path: "panel-shortcuts.png")) && ok
    model.isCommandHeld = false

    // The README image: a search, with the code item selected, so the preview has content.
    if let code = model.rows.first(where: { $0.summary.title.hasPrefix("func deploy") }) {
      model.selectedID = code.id
      await settle(model)
    }
    for scheme in [ColorScheme.light, .dark] {
      let name = scheme == .dark ? "readme-dark.png" : "readme-light.png"
      ok = saveShowcase(model, size: preferences.windowSize, scheme: scheme, to: directory.appending(path: name)) && ok
    }

    model.query = "zzzz nothing matches"
    await settle(model)
    ok = save(panel(model), size: preferences.windowSize, to: directory.appending(path: "panel-empty.png")) && ok

    // Settings use AppKit-backed controls and a toolbar. Draw the real window
    // (frame view included) offscreen, which ImageRenderer cannot do.
    // Not started: the snapshots make no network request.
    let updateChecker = UpdateChecker(preferences: preferences)
    for (index, name) in ["general", "history", "privacy", "advanced"].enumerated() {
      let window = SettingsWindowController.makeWindow(
        preferences: preferences, controller: controller, updateChecker: updateChecker, selectedTab: index
      )
      ok = await saveWindowSnapshot(window, to: directory.appending(path: "settings-\(name).png")) && ok
    }
    print(ok ? "Snapshots written to \(directory.path)" : "Some snapshots failed")
    return ok
  }

  private static func panel(_ model: PanelModel) -> some View {
    ZStack {
      LinearGradient(colors: [.indigo.opacity(0.7), .teal.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
      ClipboardView(model: model)
        .padding(1)
    }
  }

  /// The README image: the panel with a frame and a shadow, on a transparent background,
  /// so it suits the light and the dark GitHub page. Glass does not render offscreen,
  /// so an opaque fill stands in for it.
  private static func saveShowcase(_ model: PanelModel, size: CGSize, scheme: ColorScheme, to url: URL) -> Bool {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    let content = ClipboardView(model: model)
      .frame(width: size.width, height: size.height)
      .background {
        // On the frame only: a shadow on the whole view also falls on each row.
        shape
          .fill(scheme == .dark ? Color(white: 0.14) : Color(white: 0.97))
          .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.22), radius: 24, y: 10)
      }
      .overlay {
        shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.1), lineWidth: 1)
      }
      .padding(40)
      .environment(\.colorScheme, scheme)
      .environment(\.isSnapshot, true)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
          (try? data.write(to: url)) != nil else {
      print("FAIL \(url.lastPathComponent)")
      return false
    }
    return true
  }

  private static func settle(_ model: PanelModel) async {
    for _ in 0..<100 {
      try? await Task.sleep(for: .milliseconds(20))
      let detailReady = model.selectedID == nil || model.detail?.summary.id == model.selectedID
      let imageReady = model.selectedRow?.summary.kind != .image || model.previewImage != nil
      let thumbnailsReady = model.rows.filter { $0.summary.kind == .image }.allSatisfy { model.thumbnail(for: $0.id) != nil }
      if !model.isSearching && detailReady && imageReady && thumbnailsReady {
        return
      }
    }
  }

  private static func saveWindowSnapshot(_ window: NSWindow, to url: URL) async -> Bool {
    window.appearance = NSAppearance(named: .aqua)
    // Far off screen, so nothing shows while the window draws.
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    // Let SwiftUI finish layout and the first async loads (for example storage stats).
    for _ in 0..<6 {
      window.contentView?.layoutSubtreeIfNeeded()
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard let frameView = window.contentView?.superview,
          let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
      print("FAIL \(url.lastPathComponent)")
      return false
    }
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else {
      print("FAIL \(url.lastPathComponent)")
      return false
    }
    return true
  }

  @discardableResult
  private static func save(_ view: some View, size: CGSize, to url: URL) -> Bool {
    let content = view
      .frame(width: size.width, height: size.height)
      .environment(\.colorScheme, .dark)
      .environment(\.isSnapshot, true)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
      print("FAIL \(url.lastPathComponent)")
      return false
    }
    do {
      try data.write(to: url)
      return true
    } catch {
      print("FAIL \(url.lastPathComponent): \(error)")
      return false
    }
  }

  private static func seed(_ store: HistoryStore) async {
    let now = Date.now
    func text(_ value: String, app: String, bundleID: String, minutesAgo: Double, html: String? = nil) -> CapturedClip {
      var representations = [Representation(type: PasteboardTypes.string, data: Data(value.utf8))]
      if let html {
        representations.append(Representation(type: PasteboardTypes.html, data: Data(html.utf8)))
      }
      return CapturedClip(
        representations: representations, sourceBundleID: bundleID, sourceAppName: app,
        capturedAt: now.addingTimeInterval(-minutesAgo * 60)
      )
    }
    let clips: [CapturedClip] = [
      text(
        "kubectl rollout restart deployment/api -n production", app: "Terminal", bundleID: "com.apple.Terminal", minutesAgo: 400
      ),
      text("#FF9F0A", app: "Figma", bundleID: "com.figma.Desktop", minutesAgo: 300),
      text("https://github.com/pgilad/Maccy/pull/12", app: "Safari", bundleID: "com.apple.Safari", minutesAgo: 200),
      text("""
        func deploy(service: String) async throws {
          let release = try await registry.latest(for: service)
          try await cluster.rollOut(release, strategy: .canary(percent: 10))
        }
        """, app: "Safari", bundleID: "com.apple.Safari", minutesAgo: 120),
      CapturedClip(
        representations: [
          Representation(
            itemIndex: 0, type: PasteboardTypes.fileURL, data: URL(filePath: "/Users/me/Documents/Q3 Report.pdf").dataRepresentation
          ),
          Representation(
            itemIndex: 1, type: PasteboardTypes.fileURL, data: URL(filePath: "/Users/me/Documents/Budget.numbers").dataRepresentation
          ),
        ],
        sourceBundleID: "com.apple.finder", sourceAppName: "Finder", capturedAt: now.addingTimeInterval(-90 * 60)
      ),
      text(
        "Meeting notes: deploy the canary on Thursday, then watch the error budget.", app: "Notes", bundleID: "com.apple.Notes",
        minutesAgo: 45, html: "<p>Meeting notes: <b>deploy</b> the canary on Thursday</p>"
      ),
      CapturedClip(
        representations: [
          Representation(
            type: PasteboardTypes.png,
            data: Diagnostics.textImage("Build #4521 passed", size: NSSize(width: 900, height: 420))
          ),
        ],
        sourceBundleID: "com.apple.screencaptureui", sourceAppName: "Screenshot", capturedAt: now.addingTimeInterval(-20 * 60)
      ),
      text(Diagnostics.fakeAWSKey, app: "Terminal", bundleID: "com.apple.Terminal", minutesAgo: 5),
      text("Thanks! I'll deploy after lunch.", app: "Slack", bundleID: "com.tinyspeck.slackmacgap", minutesAgo: 1),
    ]
    var pinnedID: Int64?
    for clip in clips {
      guard let analyzed = ClipAnalyzer.analyze(clip) else {
        continue
      }
      let thumbnail = analyzed.primaryImage.flatMap { ImageProcessing.thumbnailPNG(from: $0, maxPixelSize: 96) }
      let expires = analyzed.detectedSecret != nil ? now.addingTimeInterval(600) : nil
      let result = try? await store.upsert(analyzed, thumbnail: thumbnail, expiresAt: expires)
      if analyzed.kind == .link {
        pinnedID = result?.id
      }
    }
    if let pinnedID {
      try? await store.setPinned(id: pinnedID, true)
    }
  }
}
#endif
