import AppKit
import MaccyCore
import Observation

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let preferences = Preferences()
  private var controller: HistoryController!
  private var panelModel: PanelModel!
  private var panel: PanelController!
  private var statusItem: StatusItemController!
  private var settings: SettingsWindowController!
  private var updateChecker: UpdateChecker!
  private var pauseObserver: DefaultsObserver?
  private var observationTasks: [Task<Void, Never>] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    Task {
      switch await Self.openStore(at: Paths.dataDirectory) {
      case .success(let store):
        finishLaunching(with: store)
      case .failure(let error):
        Log.app.fault("Cannot open the history store: \(String(describing: error), privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "Maccy cannot open its history database."
        alert.informativeText = String(describing: error)
        alert.runModal()
        NSApp.terminate(nil)
      }
    }
  }

  /// The open checks the integrity of the whole file (`PRAGMA quick_check`): about 3 s
  /// for 100,000 items. Off the main thread, the app does not hang at login.
  @concurrent
  nonisolated private static func openStore(at directory: URL) async -> Result<HistoryStore, any Error> {
    Result { try HistoryStore(directory: directory) }
  }

  private func finishLaunching(with store: HistoryStore) {
    NSApp.mainMenu = AppMenu.make()
    controller = HistoryController(preferences: preferences, store: store)
    panelModel = PanelModel(controller: controller)
    panel = PanelController(model: panelModel, preferences: preferences)
    updateChecker = UpdateChecker(preferences: preferences)
    panelModel.updateChecker = updateChecker
    settings = SettingsWindowController(preferences: preferences, controller: controller, updateChecker: updateChecker)
    statusItem = StatusItemController(
      preferences: preferences,
      controller: controller,
      onToggle: { [weak self] in self?.panel.toggle(from: .statusItem) },
      onOpenSettings: { [weak self] in self?.openSettings() },
      onOpenAbout: { [weak self] in self?.showAbout(nil) },
      onCheckForUpdates: { [weak self] in self?.checkForUpdates(nil) },
      onWillShowMenu: { [weak self] in self?.panel.close() }
    )
    panel.statusButton = statusItem.button
    controller.closePanel = { [weak self] in self?.panel.close() }
    panelModel.onOpenSettings = { [weak self] in self?.openSettings() }
    panelModel.onRequestClearHistory = { [weak self] in self?.confirmClearHistory() }

    HotKeyCenter.shared.onPress = { [weak self] in self?.panel.toggle(from: .hotKey) }
    HotKeyCenter.shared.register(preferences.hotKey)

    trackFrontmostApp()
    observePreferences()
    returnFocusWhenWindowsClose()
    // Scripts can pause capture with `defaults write … ignoreEvents`.
    pauseObserver = DefaultsObserver(keys: [Preferences.Key.ignoreEvents, Preferences.Key.ignoreOnlyNextEvent]) { [weak self] in
      self?.preferences.refreshPauseState()
    }
    controller.start()

    if !preferences.didShowOnboarding {
      preferences.didShowOnboarding = true
      openSettings()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard preferences.clearOnQuit, let controller else {
      return .terminateNow
    }
    Task {
      await controller.clearHistory(keepPinned: true)
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Opening the app again (for example from Finder) shows the panel.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    panel?.open(from: .other)
    return false
  }

  private func openSettings() {
    panel.close()
    settings.show()
  }

  @objc func showSettings(_ sender: Any?) {
    openSettings()
  }

  @objc func showAbout(_ sender: Any?) {
    panel.close()
    var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
    // The app is built from source, so show which commit is running.
    if let commit = Bundle.main.object(forInfoDictionaryKey: "MaccyGitCommit") as? String {
      let style = NSMutableParagraphStyle()
      style.alignment = .center
      options[.credits] = NSAttributedString(string: "Built from commit \(commit)", attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: style,
      ])
    }
    NSApp.orderFrontStandardAboutPanel(options: options)
    if let about = NSApp.aboutPanel {
      NSApp.showInFront(about, name: "About")
    } else {
      NSApp.activate()
    }
  }

  @objc func checkForUpdates(_ sender: Any?) {
    panel.close()
    Task { await updateChecker.check(showingResult: true) }
  }

  private func confirmClearHistory() {
    panel.close()
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "Delete all unpinned items?"
    alert.informativeText = "You cannot undo this."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    let response = alert.runModal()
    NSApp.returnFocusIfIdle()
    if response == .alertFirstButtonReturn {
      Task { await controller.clearHistory(keepPinned: true) }
    }
  }

  private func returnFocusWhenWindowsClose() {
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
      // The closing window is still visible now. Check after it is gone.
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          NSApp.returnFocusIfIdle()
        }
      }
    }
  }

  /// The capture queue cannot ask AppKit for the frontmost app, so keep a copy.
  private func trackFrontmostApp() {
    let update: @MainActor (NSRunningApplication?) -> Void = { [weak self] app in
      guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
        return
      }
      self?.controller.monitor.update(sourceApp: SourceApp(bundleID: app.bundleIdentifier, name: app.localizedName))
    }
    update(NSWorkspace.shared.frontmostApplication)
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification,
      object: nil,
      queue: .main
    ) { notification in
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated {
        update(app)
      }
    }
  }

  private func observePreferences() {
    let preferences = preferences
    let controller = controller!
    let panelModel = panelModel!
    let updateChecker = updateChecker!
    observationTasks = [
      Task {
        for await rules in Observations({ CaptureRules(preferences: preferences) }) {
          controller.monitor.update(rules: rules)
        }
      },
      Task {
        for await interval in Observations({ preferences.pollInterval }) {
          controller.monitor.start(interval: interval)
        }
      },
      Task {
        for await combo in Observations({ preferences.hotKey }) {
          HotKeyCenter.shared.register(combo)
        }
      },
      Task {
        for await enabled in Observations({ preferences.checkForUpdates }) {
          updateChecker.setAutomatic(enabled)
        }
      },
      Task { [weak self] in
        for await _ in Observations({ controller.revision }) where self?.panel.isOpen == true {
          panelModel.historyDidChange()
        }
      },
    ]
  }
}

extension NSApplication {
  /// Shows a Maccy window in front of the app that the user works in. `activate()` is
  /// only a request: after a click in the menu bar menu, macOS can keep the other app
  /// active. A window ordered front while Maccy is not active goes behind the windows
  /// of that app, so the click seems to do nothing. `orderFrontRegardless()` puts it on
  /// top anyway. It becomes key when Maccy becomes active, or when the user clicks it.
  func showInFront(_ window: NSWindow, name: String) {
    let wasActive = isActive
    activate()
    window.makeKeyAndOrderFront(nil)
    if !isActive {
      window.orderFrontRegardless()
    }
    Log.app.notice("Showed \(name, privacy: .public): app active before: \(wasActive), now: \(self.isActive)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      Log.app.notice("\(name, privacy: .public) one second later: app active: \(self.isActive), window key: \(window.isKeyWindow)")
    }
  }

  /// The panel of `orderFrontStandardAboutPanel`: the only visible panel at the normal
  /// level. (The Maccy panel floats higher, and alerts are at the modal panel level.)
  var aboutPanel: NSWindow? {
    windows.first { $0 is NSPanel && $0.isVisible && $0.level == .normal }
  }

  /// Maccy activates to show Settings, the About panel, an alert or a save panel.
  /// When the last of them closes, the app that the user worked in gets the focus
  /// back. Without this, Maccy stays active with no window and its menus in the menu bar.
  func returnFocusIfIdle() {
    let hasWindow = windows.contains { $0.isVisible && $0.level == .normal && $0.canBecomeKey }
    if isActive && !hasWindow {
      // Hiding an app activates the app behind it. The panel still opens: ordering it front unhides Maccy.
      hide(nil)
    }
  }
}

/// Key-value observation of `UserDefaults`. Unlike `didChangeNotification`,
/// it also reports changes from other processes, such as `defaults write`.
final class DefaultsObserver: NSObject {
  private let keys: [String]
  private let handler: () -> Void

  init(keys: [String], handler: @escaping () -> Void) {
    self.keys = keys
    self.handler = handler
    super.init()
    for key in keys {
      UserDefaults.standard.addObserver(self, forKeyPath: key, options: [.new], context: nil)
    }
  }

  deinit {
    for key in keys {
      UserDefaults.standard.removeObserver(self, forKeyPath: key)
    }
  }

  // The keys are strings, not key paths, so the block-based API does not apply.
  // swiftlint:disable:next block_based_kvo
  override nonisolated func observeValue(
    forKeyPath keyPath: String?,
    of object: Any?,
    change: [NSKeyValueChangeKey: Any]?,
    context: UnsafeMutableRawPointer?
  ) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        self.handler()
      }
    }
  }
}
