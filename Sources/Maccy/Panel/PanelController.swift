import AppKit
import Carbon
import MaccyCore
import SwiftUI

/// A borderless, non-activating panel. The app that the user works in stays
/// frontmost, so ⌘V goes to it after the panel closes.
final class FloatingPanel: NSPanel {
  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
      styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    isFloatingPanel = true
    // Above Chrome autofill (layer 999) and the menu bar.
    level = .screenSaver
    collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
    hidesOnDeactivate = false
    isMovableByWindowBackground = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    animationBehavior = .none
    minSize = NSSize(width: 560, height: 340)
    identifier = NSUserInterfaceItemIdentifier("com.pgilad.Maccy.panel")
    // Not shown (no title bar), but VoiceOver reads it.
    title = "Clipboard History"
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

final class PanelController: NSObject, NSWindowDelegate {
  enum OpenSource {
    case hotKey
    case statusItem
    case other
  }

  private enum CycleState {
    case idle
    /// Opened with the hot key, and its modifiers are still down.
    case opening
    /// The hot key was pressed again with the modifiers down: each press selects the next row.
    case cycling
  }

  let model: PanelModel
  private let preferences: Preferences
  private let panel = FloatingPanel()
  private var eventMonitor: Any?
  private var hotKeySuspended = false
  private var cycleState = CycleState.idle
  private(set) var isOpen = false

  weak var statusButton: NSStatusBarButton?

  init(model: PanelModel, preferences: Preferences) {
    self.model = model
    self.preferences = preferences
    super.init()
    panel.delegate = self
    model.onShowActions = { [weak self] in self?.showActions() }
    let hostingView = NSHostingView(rootView: ClipboardView(model: model))
    hostingView.sizingOptions = []
    panel.contentView = hostingView
  }

  func toggle(from source: OpenSource) {
    if isOpen {
      close()
    } else {
      open(from: source)
    }
  }

  func open(from source: OpenSource) {
    guard !isOpen else {
      return
    }
    let frontmost = NSWorkspace.shared.frontmostApplication
    let target = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
      ? nil
      : SourceApp(bundleID: frontmost?.bundleIdentifier, name: frontmost?.localizedName)
    preferences.refreshPauseState()
    model.prepareForOpen(target: target)

    // The same place for every way to open the panel (icon, shortcut, Finder).
    let position = preferences.panelPosition
    let screen = screenForPanel(position: position)
    var size = preferences.windowSize
    if let visible = screen?.visibleFrame {
      size.width = min(max(size.width, panel.minSize.width), visible.width)
      size.height = min(max(size.height, panel.minSize.height), visible.height)
    }
    panel.setContentSize(size)
    panel.setFrameOrigin(origin(for: position, size: size, screen: screen, frontmost: frontmost))
    panel.orderFrontRegardless()
    panel.makeKey()
    isOpen = true

    if source == .hotKey, let combo = preferences.hotKey,
       !NSEvent.modifierFlags.intersection(KeyCombo.relevantModifiers).isDisjoint(with: combo.modifiers) {
      cycleState = .opening
    } else {
      cycleState = .idle
    }
    // While open, the local monitor handles the hot key (toggle and cycle).
    HotKeyCenter.shared.suspend()
    hotKeySuspended = true
    installEventMonitor()
    statusButton?.highlight(source == .statusItem)
  }

  func close() {
    guard isOpen else {
      return
    }
    isOpen = false
    cycleState = .idle
    panel.orderOut(nil)
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
    }
    eventMonitor = nil
    if hotKeySuspended {
      HotKeyCenter.shared.resume()
      hotKeySuspended = false
    }
    model.editorText = nil
    statusButton?.highlight(false)
  }

  // MARK: - Window delegate

  func windowDidResignKey(_ notification: Notification) {
    close()
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    preferences.windowSize = panel.frame.size
    saveAnchor()
  }

  func windowDidMove(_ notification: Notification) {
    guard isOpen else {
      return
    }
    saveAnchor()
  }

  private func saveAnchor() {
    guard let visible = panel.screen?.visibleFrame, visible.width > 0, visible.height > 0 else {
      return
    }
    preferences.windowAnchor = CGPoint(
      x: (panel.frame.midX - visible.minX) / visible.width,
      y: (panel.frame.maxY - visible.minY) / visible.height
    )
  }

  // MARK: - Position

  private func screenForPanel(position: PanelPosition) -> NSScreen? {
    if position == .menuBarIcon, let screen = statusButton?.window?.screen {
      return screen
    }
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
  }

  private func origin(for position: PanelPosition, size: NSSize, screen: NSScreen?, frontmost: NSRunningApplication?) -> NSPoint {
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
    var origin: NSPoint
    switch position {
    case .center:
      origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.58 - size.height / 2)
    case .cursor:
      let mouse = NSEvent.mouseLocation
      origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
    case .menuBarIcon:
      if let button = statusButton, let window = button.window {
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - 4)
      } else {
        origin = NSPoint(x: visible.maxX - size.width - 8, y: visible.maxY - size.height)
      }
    case .activeWindow:
      if let frame = frontmost.flatMap(Self.windowFrame(of:)) {
        origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
      } else {
        origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
      }
    case .lastPosition:
      let anchor = preferences.windowAnchor
      origin = NSPoint(
        x: visible.minX + visible.width * anchor.x - size.width / 2,
        y: visible.minY + visible.height * anchor.y - size.height
      )
    }
    // Keep the panel on one screen.
    origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
    origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
    return origin
  }

  /// The frame of the front window of an app. Window bounds need no Screen Recording permission.
  private static func windowFrame(of app: NSRunningApplication) -> NSRect? {
    let options: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
          let primary = NSScreen.screens.first else {
      return nil
    }
    for info in list {
      guard (info[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
            (info[kCGWindowLayer as String] as? Int) == 0,
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
            let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else {
        continue
      }
      // Window bounds use a top-left origin. AppKit uses bottom-left.
      return NSRect(x: x, y: primary.frame.height - y - height, width: width, height: height)
    }
    return nil
  }

  // MARK: - Keyboard and mouse

  private func installEventMonitor() {
    let events: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
      guard let self, self.isOpen, event.window === self.panel else {
        return event
      }
      switch event.type {
      case .flagsChanged: return self.handleFlagsChanged(event)
      case .keyDown: return self.handleKeyDown(event)
      default: return self.handleMouseDown(event)
      }
    }
  }

  /// Right-click or ⌃-click on a row selects it and shows its actions, like a
  /// context menu in Finder. The menu is the same as the ⌘K menu.
  private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
    let isSecondaryClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
    guard isSecondaryClick, model.editorText == nil, let view = panel.contentView,
          let id = Self.rowID(at: event.locationInWindow, in: view, model: model) else {
      return event
    }
    let location = view.convert(event.locationInWindow, from: nil)
    Task {
      await model.select(id)
      guard isOpen else {
        return
      }
      ActionMenu.make(model.actions).popUp(positioning: nil, at: location, in: view)
    }
    return nil
  }

  /// The row under a point in window coordinates. `view` hosts `ClipboardView`.
  static func rowID(at locationInWindow: NSPoint, in view: NSView, model: PanelModel) -> Int64? {
    let location = view.convert(locationInWindow, from: nil)
    // SwiftUI frames have a top-left origin.
    let point = view.isFlipped ? location : NSPoint(x: location.x, y: view.bounds.height - location.y)
    return model.rowID(at: point)
  }

  private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
    let modifiers = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
    model.isCommandHeld = modifiers == .command
    guard modifiers.isEmpty else {
      return event
    }
    switch cycleState {
    case .cycling:
      cycleState = .idle
      model.performPrimary()
      return nil
    case .opening:
      cycleState = .idle
    case .idle:
      break
    }
    return event
  }

  // swiftlint:disable:next cyclomatic_complexity
  private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    // Let an input method finish composition (for example Japanese or Chinese input).
    if let textView = panel.firstResponder as? NSTextView, textView.hasMarkedText() {
      return event
    }

    let keyCode = Int(event.keyCode)
    let modifiers = event.modifierFlags.intersection(KeyCombo.relevantModifiers)

    // In cycle mode the modifiers are still down. ⎋ with any modifiers cancels, so
    // releasing the keys afterwards does not paste.
    if cycleState != .idle && keyCode == kVK_Escape {
      cycleState = .idle
      close()
      return nil
    }

    if let combo = preferences.hotKey, combo.matches(event) {
      if cycleState == .idle {
        close()
      } else {
        cycleState = .cycling
        model.moveNextWrapping()
      }
      return nil
    }

    let key = Self.shortcutKey(for: event)
    // The panel has no close button, so the Close menu item cannot close it.
    if key == "w" && modifiers == .command {
      close()
      return nil
    }

    if model.editorText != nil {
      switch (keyCode, modifiers) {
      case (kVK_Escape, []):
        model.editorText = nil
        return nil
      case (kVK_Return, .command), (kVK_ANSI_KeypadEnter, .command):
        model.deliverEditedText(as: model.controller.primaryDelivery)
        return nil
      default:
        return event
      }
    }

    // Special keys by key code. Letters, digits and "," by character: see shortcutKey(for:).
    switch (keyCode, modifiers) {
    case (kVK_Escape, []):
      if model.query.isEmpty && model.kindFilter == nil {
        close()
      } else {
        model.query = ""
        model.kindFilter = nil
      }
    case (kVK_DownArrow, []):
      model.move(by: 1)
    case (kVK_UpArrow, []):
      model.move(by: -1)
    case (kVK_PageDown, []):
      model.move(by: 10)
    case (kVK_PageUp, []):
      model.move(by: -10)
    case (kVK_DownArrow, .command), (kVK_End, []):
      model.moveToLast()
    case (kVK_UpArrow, .command), (kVK_Home, []):
      model.moveToFirst()
    case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
      model.performPrimary()
    case (kVK_Return, .command), (kVK_ANSI_KeypadEnter, .command):
      model.performSecondary()
    case (kVK_Return, .option), (kVK_Return, [.option, .shift]):
      model.pastePlainText()
    case (kVK_Delete, .command) where model.query.isEmpty:
      // While the user types, ⌘⌫ keeps its text meaning (delete to the line start).
      model.deleteSelected()
    case (kVK_Delete, [.command, .shift]):
      model.onRequestClearHistory()
    default:
      return handleCharacterKey(key, modifiers: modifiers) ? nil : event
    }
    return nil
  }

  /// Returns `false` for a key that the panel does not handle.
  private func handleCharacterKey(_ key: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
    switch (key, modifiers) {
    case ("n"?, .control), ("j"?, .control):
      model.move(by: 1)
    case ("p"?, .control), ("k"?, .control):
      model.move(by: -1)
    case ("k"?, .command):
      showActions()
    case (","?, .command):
      model.onOpenSettings()
    case ("p"?, .command):
      model.cycleKindFilter()
    case ("p"?, [.command, .shift]):
      model.togglePin()
    case ("e"?, .command):
      model.beginEditing()
    case let (key?, modifiers) where ["o", "s", "f", "c"].contains(key) && !modifiers.isEmpty:
      return runAction(key: key, modifiers: modifiers)
    case let (key?, .command) where key.count == 1 && ("1"..."9").contains(key):
      model.performPrimary(atRow: Int(key)! - 1)
    default:
      return false
    }
    return true
  }

  /// The key of a shortcut, as the menus show it: the character that the layout
  /// types, so ⌘W is the key labeled W on Dvorak or AZERTY. Before, the panel
  /// matched US key positions, and on Dvorak ⌘W opened Settings. A layout without
  /// that character (Hebrew, Russian, or AZERTY digits) uses the US key position,
  /// like the menus do.
  static func shortcutKey(for event: NSEvent) -> String? {
    if let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1,
       let character = characters.first, character.isASCII, character.isLetter || character.isNumber || character == "," {
      return characters
    }
    return usKeys[Int(event.keyCode)]
  }

  private static let usKeys: [Int: String] = [
    kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e", kVK_ANSI_F: "f",
    kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
    kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r",
    kVK_ANSI_S: "s", kVK_ANSI_T: "t", kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
    kVK_ANSI_Y: "y", kVK_ANSI_Z: "z", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
    kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_ANSI_Comma: ",",
  ]

  /// Runs the action that has this shortcut, if the selected item supports it.
  private func runAction(key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
    guard let action = model.actions.first(where: { $0.keyEquivalent == key && $0.modifiers == modifiers }) else {
      return false
    }
    action.perform()
    return true
  }

  /// Shows the actions as a native menu above the Actions button.
  func showActions() {
    guard isOpen, let view = panel.contentView else {
      return
    }
    ActionMenu.popUp(ActionMenu.make(model.actions), in: view, footerHeight: FooterBar.height)
  }
}
