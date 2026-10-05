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

  var button: NSStatusBarButton? { statusItem.button }

  init(preferences: Preferences, controller: HistoryController, onToggle: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
    self.preferences = preferences
    self.controller = controller
    self.onToggle = onToggle
    self.onOpenSettings = onOpenSettings
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
  }

  private func observe() {
    Task { [weak self] in
      guard let self else {
        return
      }
      let changes = Observations { [preferences, controller] in
        (preferences.menuIcon, preferences.isPaused, preferences.showInMenuBar,
         preferences.showRecentCopyInMenuBar, controller.latestTitle)
      }
      for await _ in changes {
        update()
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
    let modifiers = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
    if event?.type == .rightMouseUp || modifiers.contains(.control) {
      showMenu()
    } else if modifiers.contains(.option) {
      // ⌥-click pauses; ⇧⌥-click skips only the next copy (upstream Maccy behavior).
      preferences.refreshPauseState()
      if preferences.isPaused {
        preferences.ignoreEvents = false
        preferences.pauseUntil = nil
      } else {
        preferences.ignoreEvents = true
        preferences.ignoreOnlyNextEvent = modifiers.contains(.shift)
      }
    } else {
      onToggle()
    }
  }

  private func showMenu() {
    preferences.refreshPauseState()
    let menu = NSMenu()
    let open = menu.addItem(withTitle: "Open Maccy", action: #selector(openPanel), keyEquivalent: "")
    open.target = self
    if let hotKey = preferences.hotKey {
      open.title = "Open Maccy  (\(hotKey.displayString))"
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
    menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
    menu.addItem(withTitle: "Quit Maccy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    // Remove the menu again, so the next left click opens the panel.
    statusItem.menu = nil
  }

  @objc private func openPanel() { onToggle() }
  @objc private func openSettings() { onOpenSettings() }

  @objc private func resume() {
    preferences.ignoreEvents = false
    preferences.ignoreOnlyNextEvent = false
    preferences.pauseUntil = nil
  }

  @objc private func pauseFor(_ sender: NSMenuItem) {
    preferences.pauseUntil = Date.now.addingTimeInterval(Double(sender.tag) * 60)
    // Update the icon when the pause ends.
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(sender.tag) * 60 + 1) { [weak self] in
      self?.preferences.refreshPauseState()
    }
  }

  @objc private func pauseIndefinitely() {
    preferences.ignoreEvents = true
  }

  @objc private func skipNext() {
    preferences.ignoreEvents = true
    preferences.ignoreOnlyNextEvent = true
  }
}
