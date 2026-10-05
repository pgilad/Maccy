import AppKit
import SwiftUI

final class SettingsWindowController {
  private var window: NSWindow?
  private let preferences: Preferences
  private let controller: HistoryController

  init(preferences: Preferences, controller: HistoryController) {
    self.preferences = preferences
    self.controller = controller
  }

  func show() {
    if window == nil {
      let hosting = NSHostingController(rootView: SettingsView(preferences: preferences, controller: controller))
      hosting.sizingOptions = [.preferredContentSize]
      let window = NSWindow(contentViewController: hosting)
      window.title = "Maccy Settings"
      window.styleMask = [.titled, .closable, .miniaturizable]
      window.isReleasedWhenClosed = false
      window.center()
      self.window = window
    }
    // Maccy is a menu bar app (no Dock icon), so it must activate to show a normal window.
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
  }
}
