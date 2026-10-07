import AppKit
import SwiftUI

/// A native settings window: toolbar tabs with icons, the window title follows
/// the tab, and the window resizes to each pane (like Safari or Mail settings).
/// It opens where it was last, on the last tab.
final class SettingsWindowController {
  private struct Pane {
    let title: String
    let symbol: String
    let height: CGFloat
    let view: AnyView
  }

  static let width: CGFloat = 560
  private static let frameName = "Settings"

  private var window: NSWindow?
  private let preferences: Preferences
  private let controller: HistoryController
  private let updateChecker: UpdateChecker

  init(preferences: Preferences, controller: HistoryController, updateChecker: UpdateChecker) {
    self.preferences = preferences
    self.controller = controller
    self.updateChecker = updateChecker
  }

  func show() {
    if window == nil {
      let window = Self.makeWindow(preferences: preferences, controller: controller, updateChecker: updateChecker)
      if !window.setFrameUsingName(Self.frameName) {
        window.center()
      }
      window.setFrameAutosaveName(Self.frameName)
      self.window = window
    }
    // Maccy is a menu bar app (no Dock icon), so it must activate to show a normal window.
    if let window {
      NSApp.showInFront(window, name: "Settings")
    }
  }

  static func makeWindow(
    preferences: Preferences,
    controller: HistoryController,
    updateChecker: UpdateChecker,
    selectedTab: Int? = nil
  ) -> NSWindow {
    let panes = [
      Pane(title: "General", symbol: "gearshape", height: 800, view: AnyView(GeneralSettings(preferences: preferences))),
      Pane(title: "History", symbol: "clock.arrow.circlepath", height: 715,
           view: AnyView(HistorySettings(preferences: preferences, controller: controller))),
      Pane(title: "Privacy", symbol: "hand.raised", height: 720, view: AnyView(PrivacySettings(preferences: preferences))),
      Pane(title: "Advanced", symbol: "gearshape.2", height: 420,
           view: AnyView(AdvancedSettings(preferences: preferences, updateChecker: updateChecker))),
    ]

    let tabs = SettingsTabViewController()
    tabs.tabStyle = .toolbar
    // Switch tabs at once: no crossfade, and the window resizes without animation.
    tabs.transitionOptions = []
    for pane in panes {
      let hosting = NSHostingController(rootView: pane.view.frame(width: width, height: pane.height))
      hosting.sizingOptions = [.preferredContentSize]
      hosting.title = pane.title
      let item = NSTabViewItem(viewController: hosting)
      item.label = pane.title
      item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
      tabs.addTabViewItem(item)
    }
    tabs.selectedTabViewItemIndex = min(max(selectedTab ?? preferences.settingsTab, 0), panes.count - 1)
    tabs.onSelect = { preferences.settingsTab = $0 }

    let window = NSWindow(contentViewController: tabs)
    // Like the settings of Apple's apps: no minimize or zoom.
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.identifier = NSUserInterfaceItemIdentifier("com.pgilad.Maccy.settings")
    return window
  }
}

private final class SettingsTabViewController: NSTabViewController {
  var onSelect: (Int) -> Void = { _ in }

  override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
    super.tabView(tabView, didSelect: tabViewItem)
    onSelect(selectedTabViewItemIndex)
  }
}
