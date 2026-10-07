import AppKit
import Observation

/// The menu bar icon. Click: open the panel. ⌥-click: pause or resume capture.
/// Right-click or ⌃-click: menu.
final class StatusItemController: NSObject, NSMenuDelegate {
  private let preferences: Preferences
  private let controller: HistoryController
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let onToggle: () -> Void
  private let onOpenSettings: () -> Void
  private let onOpenAbout: () -> Void
  private let onWillShowMenu: () -> Void
  private var visibilityObservation: NSKeyValueObservation?

  var button: NSStatusBarButton? { statusItem.button }

  init(
    preferences: Preferences,
    controller: HistoryController,
    onToggle: @escaping () -> Void,
    onOpenSettings: @escaping () -> Void,
    onOpenAbout: @escaping () -> Void,
    onWillShowMenu: @escaping () -> Void
  ) {
    self.preferences = preferences
    self.controller = controller
    self.onToggle = onToggle
    self.onOpenSettings = onOpenSettings
    self.onOpenAbout = onOpenAbout
    self.onWillShowMenu = onWillShowMenu
    super.init()
    statusItem.behavior = .removalAllowed
    if let button = statusItem.button {
      button.target = self
      button.action = #selector(click)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
      button.imagePosition = .imageLeft
    }
    update()
    observe()
    // ⌘-dragging the icon out of the menu bar hides it. Keep the setting in step.
    visibilityObservation = statusItem.observe(\.isVisible, options: [.new]) { [weak self] _, change in
      guard let visible = change.newValue else {
        return
      }
      MainActor.assumeIsolated {
        if let preferences = self?.preferences, preferences.showInMenuBar != visible {
          preferences.showInMenuBar = visible
        }
      }
    }
  }

  private func observe() {
    // The endless loop holds `self` weakly. Before, it bound `self` strongly first.
    let changes = Observations { [preferences, controller] in
      (preferences.menuIcon, preferences.isPaused, preferences.showInMenuBar,
       preferences.showRecentCopyInMenuBar, controller.latestTitle)
    }
    Task { [weak self] in
      for await _ in changes {
        self?.update()
      }
    }
  }

  func update() {
    statusItem.isVisible = preferences.showInMenuBar
    guard let button = statusItem.button else {
      return
    }
    button.image = preferences.menuIcon.image
    button.appearsDisabled = preferences.isPaused
    if preferences.showRecentCopyInMenuBar, let title = controller.latestTitle, !title.isEmpty {
      button.title = " " + String(title.prefix(20))
    } else {
      button.title = ""
    }
    button.setAccessibilityLabel(preferences.isPaused ? "Maccy, capture paused" : "Maccy")
  }

  @objc private func click() {
    let event = NSApp.currentEvent
    // macOS 27 can send the action without the modifier keys of the click. Add the keys that are down now.
    let modifiers = (event?.modifierFlags ?? []).union(NSEvent.modifierFlags).intersection(.deviceIndependentFlagsMask)
    if event?.type == .rightMouseUp || modifiers.contains(.control) {
      showMenu()
    } else if modifiers.contains(.option) {
      // ⌥-click pauses; ⇧⌥-click skips only the next copy (upstream Maccy behavior).
      preferences.refreshPauseState()
      if preferences.isPaused {
        preferences.resume()
      } else if modifiers.contains(.shift) {
        preferences.skipNextCopy()
      } else {
        preferences.pause()
      }
    } else {
      onToggle()
    }
  }

  private func showMenu() {
    // The panel floats above menu bar menus (it must cover Chrome autofill pop-ups),
    // so it would hide this menu. A click in the menu bar dismisses the panel anyway.
    onWillShowMenu()
    preferences.refreshPauseState()
    let menu = NSMenu()
    let open = menu.addItem(withTitle: "Open Maccy", action: #selector(openPanel), keyEquivalent: "")
    open.target = self
    // Show the global shortcut where menus show shortcuts: at the trailing edge.
    if let hotKey = preferences.hotKey {
      if let key = hotKey.menuKeyEquivalent {
        open.keyEquivalent = key
        open.keyEquivalentModifierMask = hotKey.modifiers
      } else {
        open.title = "Open Maccy (\(hotKey.displayString))"
      }
    }
    menu.addItem(.separator())
    if preferences.isPaused {
      let title = preferences.pauseUntil.map { "Resume Capture (paused until \($0.formatted(date: .omitted, time: .shortened)))" }
        ?? "Resume Capture"
      menu.addItem(withTitle: title, action: #selector(resume), keyEquivalent: "").target = self
    } else {
      for (title, minutes) in [("Pause for 5 Minutes", 5), ("Pause for 30 Minutes", 30), ("Pause for 1 Hour", 60)] {
        let item = menu.addItem(withTitle: title, action: #selector(pauseFor(_:)), keyEquivalent: "")
        item.target = self
        item.tag = minutes
      }
      menu.addItem(withTitle: "Pause Until Resumed", action: #selector(pauseIndefinitely), keyEquivalent: "").target = self
      menu.addItem(withTitle: "Skip Next Copy", action: #selector(skipNext), keyEquivalent: "").target = self
    }
    menu.addItem(.separator())
    // macOS adds icons to Settings and Quit, and to About only with the standard
    // About action. Without an icon, About is indented to align with Settings.
    let about = menu.addItem(withTitle: "About Maccy", action: #selector(openAbout), keyEquivalent: "")
    about.target = self
    about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
    menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Maccy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    // Remove the menu again, so the next left click opens the panel.
    statusItem.menu = nil
  }

  @objc private func openPanel() { onToggle() }
  @objc private func openSettings() { onOpenSettings() }
  @objc private func openAbout() { onOpenAbout() }

  @objc private func resume() {
    preferences.resume()
  }

  @objc private func pauseFor(_ sender: NSMenuItem) {
    let seconds = Double(sender.tag) * 60
    preferences.pause(until: Date.now.addingTimeInterval(seconds))
    // Update the icon when the pause ends. The wall clock, not the uptime clock:
    // capture resumes by the wall clock, and the uptime clock stops while the Mac sleeps.
    DispatchQueue.main.asyncAfter(wallDeadline: .now() + seconds + 1) { [weak self] in
      self?.preferences.refreshPauseState()
    }
  }

  @objc private func pauseIndefinitely() {
    preferences.pause()
  }

  @objc private func skipNext() {
    preferences.skipNextCopy()
  }
}
