import AppKit
import SwiftUI

/// A native settings window: toolbar tabs with icons, the window title follows
/// the tab, and the window resizes to each pane (like Safari or Mail settings).
final class SettingsWindowController {
  private struct Pane {
    let title: String
    let symbol: String
    let height: CGFloat
    let view: AnyView
  }

  static let width: CGFloat = 560

  private var window: NSWindow?
  private let preferences: Preferences
  private let controller: HistoryController

  init(preferences: Preferences, controller: HistoryController) {
    self.preferences = preferences
    self.controller = controller
  }

  func show() {
    if window == nil {
      window = Self.makeWindow(preferences: preferences, controller: controller)
      window?.center()
    }
    // Maccy is a menu bar app (no Dock icon), so it must activate to show a normal window.
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
  }

  static func makeWindow(preferences: Preferences, controller: HistoryController, selectedTab: Int = 0) -> NSWindow {
    let panes = [
      Pane(title: "General", symbol: "gearshape", height: 800, view: AnyView(GeneralSettings(preferences: preferences))),
      Pane(title: "History", symbol: "clock.arrow.circlepath", height: 715,
           view: AnyView(HistorySettings(preferences: preferences, controller: controller))),
      Pane(title: "Privacy", symbol: "hand.raised", height: 720, view: AnyView(PrivacySettings(preferences: preferences))),
      Pane(title: "Advanced", symbol: "gearshape.2", height: 250, view: AnyView(AdvancedSettings(preferences: preferences))),
    ]

    let tabs = NSTabViewController()
    tabs.tabStyle = .toolbar
    tabs.transitionOptions = [.crossfade, .allowUserInteraction]
    for pane in panes {
      let hosting = NSHostingController(rootView: pane.view.frame(width: width, height: pane.height))
      hosting.sizingOptions = [.preferredContentSize]
      hosting.title = pane.title
      let item = NSTabViewItem(viewController: hosting)
      item.label = pane.title
      item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
      tabs.addTabViewItem(item)
    }
    tabs.selectedTabViewItemIndex = selectedTab

    let window = NSWindow(contentViewController: tabs)
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.identifier = NSUserInterfaceItemIdentifier("com.pgilad.Maccy.settings")
    return window
  }
}
