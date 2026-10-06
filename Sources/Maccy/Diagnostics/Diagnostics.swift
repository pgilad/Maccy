#if DEBUG
import AppKit
import Carbon
import MaccyCore
import SwiftUI

/// Development checks that need no Xcode and do not touch the real clipboard:
///
/// - `Maccy --self-test`: runs the real capture, store, search and write-back
///   code against a private, named pasteboard and a temporary store.
/// - `Maccy --render-snapshots <dir>`: renders the panel and the settings
///   with sample data to PNG files.
enum Diagnostics {
  /// Returns `true` when a diagnostic started. It calls `exit` when it ends.
  static func startIfRequested(_ arguments: [String]) -> Bool {
    if arguments.contains("--self-test") {
      Task { exit(await SelfTest().run() ? 0 : 1) }
      return true
    }
    if let index = arguments.firstIndex(of: "--render-snapshots"), arguments.indices.contains(index + 1) {
      let directory = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
      Task { exit(await SnapshotRenderer.render(to: directory) ? 0 : 1) }
      return true
    }
    return false
  }

  // Fake credentials, built from parts so that no token-shaped literal is in the
  // repository (GitHub push protection and secret scanners flag those).
  static let fakeAWSKey = "AKIA" + "IOSFODNN7" + "EXAMPLE"
  static let fakeGitHubToken = "gh" + "p_" + "abcdefghijklmnopqrstuvwxyz0123456789"

  static func temporaryDirectory(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "Maccy-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func isolatedDefaults(_ name: String) -> UserDefaults {
    let suite = "com.pgilad.Maccy.\(name)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
  }

  /// An image with text, for the OCR check.
  static func textImage(_ text: String, size: NSSize = NSSize(width: 640, height: 160)) -> Data {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    (text as NSString).draw(at: NSPoint(x: 30, y: 50), withAttributes: [
      .font: NSFont.systemFont(ofSize: 44, weight: .semibold),
      .foregroundColor: NSColor.black,
    ])
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
  }
}

@MainActor
final class SelfTest {
  private var failures = 0
  private var passes = 0

  // A linear script: each step depends on the one before it.
  // swiftlint:disable:next function_body_length
  func run() async -> Bool {
    let directory = Diagnostics.temporaryDirectory("selftest")
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = Diagnostics.isolatedDefaults("selftest")
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.pgilad.Maccy.selftest.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    let preferences = Preferences(defaults: defaults)
    let store: HistoryStore
    do {
      store = try HistoryStore(directory: directory)
    } catch {
      print("FAIL cannot open store: \(error)")
      return false
    }
    let controller = HistoryController(preferences: preferences, store: store, pasteboard: pasteboard, defaults: defaults)
    controller.monitor.update(rules: CaptureRules(preferences: preferences))
    controller.monitor.update(sourceApp: SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit"))

    // 1. Plain text.
    await copy(to: pasteboard, controller: controller) { $0.setString("hello self-test", forType: .string) }
    var recent = (try? await store.recent(limit: 10)) ?? []
    check(recent.count == 1 && recent.first?.kind == .text, "plain text is saved")
    check(recent.first?.appName == "TextEdit", "source app is recorded")

    // 2. The same text again is one item with two copies.
    await copy(to: pasteboard, controller: controller) { $0.setString("hello self-test", forType: .string) }
    recent = (try? await store.recent(limit: 10)) ?? []
    check(recent.count == 1 && recent.first?.copyCount == 2, "duplicate copy merges into one item")

    // 3. Concealed (password manager) copies are never saved.
    await copy(to: pasteboard, controller: controller, expectCapture: false) {
      $0.setString("hunter2", forType: .string)
      $0.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardTypes.concealed))
    }
    check(await count(store) == 1, "concealed copy is not saved")

    // 4. Rich text.
    await copy(to: pasteboard, controller: controller) {
      $0.setString("Bold words", forType: .string)
      $0.setString("<b>Bold</b> words", forType: .html)
    }
    recent = (try? await store.recent(limit: 10)) ?? []
    check(recent.first?.hasRichText == true, "rich text is saved with its HTML")

    // 5. Image with text: thumbnail, OCR, search.
    let ocrBefore = controller.processedOCR
    await copy(to: pasteboard, controller: controller) {
      $0.setData(Diagnostics.textImage("Invoice 48213"), forType: .png)
    }
    recent = (try? await store.recent(limit: 10)) ?? []
    let imageID = recent.first?.id ?? -1
    check(recent.first?.kind == .image && recent.first?.imageWidth == 640, "image is saved with its size")
    check((try? await store.thumbnail(id: imageID)) != nil, "image thumbnail is made at capture")
    await waitUntil { controller.processedOCR > ocrBefore }
    let ocrHits = (try? await store.search(SearchQuery.parse("48213"), limit: 10).hits) ?? []
    check(ocrHits.first?.id == imageID, "text in the image is searchable (OCR)")

    // 6. Files.
    await copy(to: pasteboard, controller: controller) {
      $0.writeObjects([URL(filePath: "/Applications/Safari.app") as NSURL, URL(filePath: "/tmp/report.pdf") as NSURL])
    }
    recent = (try? await store.recent(limit: 10)) ?? []
    check(recent.first?.kind == .file && recent.first?.fileCount == 2, "multiple files are one item")

    // 7. Secrets expire.
    await copy(to: pasteboard, controller: controller) { $0.setString(Diagnostics.fakeAWSKey, forType: .string) }
    recent = (try? await store.recent(limit: 10)) ?? []
    check(recent.first?.isSensitive == true && recent.first?.expiresAt != nil, "secret is marked and expires")
    preferences.secretPolicy = .dontSave
    controller.monitor.update(rules: CaptureRules(preferences: preferences))
    let beforeSecret = await count(store)
    await copy(to: pasteboard, controller: controller) { $0.setString(Diagnostics.fakeGitHubToken, forType: .string) }
    check(await count(store) == beforeSecret, "secret is not saved with the 'do not save' policy")

    // 8. Ignored apps.
    controller.monitor.update(sourceApp: SourceApp(bundleID: "com.1password.1password", name: "1Password"))
    await copy(to: pasteboard, controller: controller, expectCapture: false) { $0.setString("from a password manager", forType: .string) }
    check(await count(store) == beforeSecret, "copies from an ignored app are not saved")
    controller.monitor.update(sourceApp: SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit"))

    // 9. Pause.
    defaults.set(true, forKey: Preferences.Key.ignoreEvents)
    defaults.set(true, forKey: Preferences.Key.ignoreOnlyNextEvent)
    await copy(to: pasteboard, controller: controller, expectCapture: false) { $0.setString("skipped once", forType: .string) }
    check(await count(store) == beforeSecret, "'skip next copy' skips one copy")
    await copy(to: pasteboard, controller: controller) { $0.setString("after the skip", forType: .string) }
    check(await count(store) == beforeSecret + 1, "capture resumes after the skipped copy")

    // 10. Write-back: Maccy's own write is not captured again, and the item moves to the top.
    let textID = (try? await store.search(SearchQuery.parse("hello self-test"), limit: 1).hits.first?.id) ?? -1
    let beforeDeliver = await count(store)
    await controller.deliver(textID, as: .copy)
    await controller.monitor.checkNow()
    try? await Task.sleep(for: .milliseconds(100))
    check(await count(store) == beforeDeliver, "Maccy's own write is not saved again")
    check(pasteboard.string(forType: .string) == "hello self-test", "write-back restores the text")
    check((try? await store.recent(limit: 1).first?.id) == textID, "delivered item moves to the top")

    await controller.deliver(imageID, as: .copy)
    check(pasteboard.data(forType: .png) != nil, "write-back restores the PNG")
    check(pasteboard.data(forType: .tiff) != nil, "write-back offers TIFF on demand")

    let richID = (try? await store.search(SearchQuery.parse("Bold words"), limit: 1).hits.first?.id) ?? -1
    await controller.deliver(richID, as: .copy, plainText: true)
    check(
      pasteboard.data(forType: .html) == nil && pasteboard.string(forType: .string) == "Bold words",
      "plain-text paste drops formatting"
    )

    await controller.deliver(imageID, as: .copy, plainText: true)
    check(pasteboard.data(forType: .png) != nil, "plain-text paste of an image keeps the image")

    // 11. Search syntax.
    let images = (try? await store.search(SearchQuery.parse("type:image"), limit: 10).hits) ?? []
    check(images.map(\.id) == [imageID], "type filter")
    let regex = (try? await store.search(SearchQuery.parse("/hel+o/"), limit: 10).hits) ?? []
    check(regex.first?.id == textID, "regex search")

    // 12. Actions menu: the chosen item runs its own action, not the first one.
    let model = PanelModel(controller: controller)
    var openedSettings = false
    var requestedClear = false
    model.onOpenSettings = { openedSettings = true }
    model.onRequestClearHistory = { requestedClear = true }
    let menu = ActionMenu.make(model.actions)
    let settingsIndex = menu.items.firstIndex { $0.identifier?.rawValue == "settings" }
    if let settingsIndex {
      menu.performActionForItem(at: settingsIndex)
    }
    check(openedSettings && !requestedClear, "actions menu runs the chosen action")
    check(menu.items.first(where: { $0.identifier?.rawValue == "settings" })?.keyEquivalent == ",", "actions menu shows key equivalents")

    // 13. Settings: a tab switch resizes the window with no animation. Sample the
    // height: an animation shows heights between the old and the new value.
    let settings = SettingsWindowController.makeWindow(preferences: preferences, controller: controller)
    settings.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    settings.orderFrontRegardless()
    try? await Task.sleep(for: .milliseconds(200))
    let generalHeight = settings.frame.height
    (settings.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex = 3
    var heights: [CGFloat] = []
    for _ in 0..<40 {
      heights.append(settings.frame.height)
      try? await Task.sleep(for: .milliseconds(10))
    }
    settings.orderOut(nil)
    let finalHeight = heights.last ?? generalHeight
    let intermediate = heights.filter { $0 != generalHeight && $0 != finalHeight }
    print("  settings heights: \(Array(NSOrderedSet(array: heights)))")
    check(finalHeight < generalHeight && intermediate.isEmpty, "settings tab switch has no animation")
    check(!settings.styleMask.contains(.miniaturizable), "settings window has no minimize button, like Apple's settings")
    let reopened = SettingsWindowController.makeWindow(preferences: preferences, controller: controller)
    check((reopened.contentViewController as? NSTabViewController)?.selectedTabViewItemIndex == 3, "settings reopen on the last tab")

    // 14. Right-click: a point on a row finds that row; a point in the search bar finds none.
    model.prepareForOpen(target: nil)
    await waitUntil { !model.isSearching && !model.rows.isEmpty }
    let host = NSHostingView(rootView: ClipboardView(model: model))
    let panelWindow = NSWindow(
      contentRect: NSRect(x: -20_000, y: -20_000, width: 780, height: 500), styleMask: .borderless, backing: .buffered, defer: false
    )
    panelWindow.contentView = host
    panelWindow.orderFrontRegardless()
    await waitUntil(timeout: .seconds(3)) { model.rowFrames[model.rows[0].id] != nil }
    let firstRow = model.rowFrames[model.rows[0].id] ?? .zero
    // Window coordinates have a bottom-left origin.
    let onRow = NSPoint(x: firstRow.midX, y: host.bounds.height - firstRow.midY)
    let inSearchBar = NSPoint(x: 200, y: host.bounds.height - 20)
    check(PanelController.rowID(at: onRow, in: host, model: model) == model.rows[0].id, "right-click finds the row under the pointer")
    check(PanelController.rowID(at: inSearchBar, in: host, model: model) == nil, "right-click outside the list finds no row")
    panelWindow.orderOut(nil)

    // 15. Menus: About in the app menu, and the global shortcut as a menu key equivalent.
    let appMenu = AppMenu.make().items.first?.submenu
    check(appMenu?.items.first?.action == #selector(AppDelegate.showAbout(_:)), "app menu starts with About Maccy")
    check(KeyCombo(keyCode: UInt16(kVK_F5), modifiers: .option).menuKeyEquivalent == String(Character(NSEvent.SpecialKey.f5.unicodeScalar)),
          "a function-key shortcut becomes a menu key equivalent")

    print("\nSelf-test: \(passes) passed, \(failures) failed")
    return failures == 0
  }

  private func check(_ condition: Bool, _ name: String) {
    if condition {
      passes += 1
      print("PASS \(name)")
    } else {
      failures += 1
      print("FAIL \(name)")
    }
  }

  private func count(_ store: HistoryStore) async -> Int {
    (try? await store.stats().itemCount) ?? -1
  }

  /// Writes to the pasteboard, runs one monitor check, and waits for the pipeline.
  private func copy(
    to pasteboard: NSPasteboard,
    controller: HistoryController,
    expectCapture: Bool = true,
    _ write: (NSPasteboard) -> Void
  ) async {
    let before = controller.processedCaptures
    pasteboard.clearContents()
    write(pasteboard)
    await controller.monitor.checkNow()
    if expectCapture {
      await waitUntil { controller.processedCaptures > before }
    } else {
      try? await Task.sleep(for: .milliseconds(100))
    }
  }

  private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() && ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }
}
#endif
