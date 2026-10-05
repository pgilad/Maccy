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
  private var pauseObserver: DefaultsObserver?
  private var observationTasks: [Task<Void, Never>] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    let store: HistoryStore
    do {
      store = try HistoryStore(directory: Paths.dataDirectory)
    } catch {
      Log.app.fault("Cannot open the history store: \(String(describing: error), privacy: .public)")
      let alert = NSAlert()
      alert.messageText = "Maccy cannot open its history database."
      alert.informativeText = String(describing: error)
      alert.runModal()
      NSApp.terminate(nil)
      return
    }

    NSApp.mainMenu = AppMenu.make()
    controller = HistoryController(preferences: preferences, store: store)
    panelModel = PanelModel(controller: controller)
    panel = PanelController(model: panelModel, preferences: preferences)
    settings = SettingsWindowController(preferences: preferences, controller: controller)
    statusItem = StatusItemController(
      preferences: preferences,
      controller: controller,
      onToggle: { [weak self] in self?.panel.toggle(from: .statusItem) },
      onOpenSettings: { [weak self] in self?.openSettings() }
    )
    panel.statusButton = statusItem.button
    controller.closePanel = { [weak self] in self?.panel.close() }
    panelModel.onOpenSettings = { [weak self] in self?.openSettings() }
    panelModel.onRequestClearHistory = { [weak self] in self?.confirmClearHistory() }

    HotKeyCenter.shared.onPress = { [weak self] in self?.panel.toggle(from: .hotKey) }
    HotKeyCenter.shared.register(preferences.hotKey)

    trackFrontmostApp()
    observePreferences()
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

  private func confirmClearHistory() {
    panel.close()
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "Delete all unpinned items?"
    alert.informativeText = "You cannot undo this."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    if alert.runModal() == .alertFirstButtonReturn {
      Task { await controller.clearHistory(keepPinned: true) }
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
      Task { [weak self] in
        for await _ in Observations({ controller.revision }) {
          if self?.panel.isOpen == true {
            panelModel.historyDidChange()
          }
        }
      },
    ]
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
