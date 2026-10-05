import AppKit
import Carbon

/// A key with modifiers, for example ⇧⌘C.
struct KeyCombo: Codable, Hashable, Sendable {
  static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

  var keyCode: UInt16
  var modifierRawValue: UInt

  init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
    self.keyCode = keyCode
    self.modifierRawValue = modifiers.intersection(Self.relevantModifiers).rawValue
  }

  init?(event: NSEvent) {
    guard event.type == .keyDown else {
      return nil
    }
    self.init(keyCode: event.keyCode, modifiers: event.modifierFlags)
  }

  static let defaultPopup = KeyCombo(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command, .shift])

  var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRawValue) }

  var carbonModifiers: UInt32 {
    var result: UInt32 = 0
    if modifiers.contains(.command) { result |= UInt32(cmdKey) }
    if modifiers.contains(.option) { result |= UInt32(optionKey) }
    if modifiers.contains(.control) { result |= UInt32(controlKey) }
    if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
    return result
  }

  /// Function keys can be used without modifiers. Other keys need ⌘, ⌥ or ⌃.
  var isValidGlobalShortcut: Bool {
    if Self.functionKeys.contains(Int(keyCode)) {
      return true
    }
    return !modifiers.intersection([.command, .option, .control]).isEmpty
  }

  func matches(_ event: NSEvent) -> Bool {
    event.keyCode == keyCode && event.modifierFlags.intersection(Self.relevantModifiers) == modifiers
  }

  var displayString: String {
    modifierSymbols + keyName
  }

  var modifierSymbols: String {
    var symbols = ""
    if modifiers.contains(.control) { symbols += "⌃" }
    if modifiers.contains(.option) { symbols += "⌥" }
    if modifiers.contains(.shift) { symbols += "⇧" }
    if modifiers.contains(.command) { symbols += "⌘" }
    return symbols
  }

  var keyName: String {
    if let name = Self.specialKeyNames[Int(keyCode)] {
      return name
    }
    return KeyboardLayout.character(forKeyCode: keyCode)?.uppercased() ?? "#\(keyCode)"
  }

  /// The key as an `NSMenuItem` key equivalent, so a menu can show the shortcut.
  var menuKeyEquivalent: String? {
    switch Int(keyCode) {
    case kVK_Space: return " "
    case kVK_Escape: return "\u{1B}"
    default: break
    }
    if let key = Self.specialMenuKeys[Int(keyCode)] {
      return String(Character(key.unicodeScalar))
    }
    return KeyboardLayout.character(forKeyCode: keyCode)?.lowercased()
  }

  private static let specialMenuKeys: [Int: NSEvent.SpecialKey] = [
    kVK_Return: .carriageReturn, kVK_Tab: .tab, kVK_Delete: .backspace, kVK_ForwardDelete: .deleteForward,
    kVK_LeftArrow: .leftArrow, kVK_RightArrow: .rightArrow, kVK_UpArrow: .upArrow, kVK_DownArrow: .downArrow,
    kVK_Home: .home, kVK_End: .end, kVK_PageUp: .pageUp, kVK_PageDown: .pageDown, kVK_ANSI_KeypadEnter: .enter,
    kVK_F1: .f1, kVK_F2: .f2, kVK_F3: .f3, kVK_F4: .f4, kVK_F5: .f5, kVK_F6: .f6, kVK_F7: .f7, kVK_F8: .f8,
    kVK_F9: .f9, kVK_F10: .f10, kVK_F11: .f11, kVK_F12: .f12, kVK_F13: .f13, kVK_F14: .f14, kVK_F15: .f15,
    kVK_F16: .f16, kVK_F17: .f17, kVK_F18: .f18, kVK_F19: .f19, kVK_F20: .f20,
  ]

  private static let functionKeys: Set<Int> = [
    kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
    kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
  ]

  private static let specialKeyNames: [Int: String] = [
    kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
    kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
    kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    kVK_ANSI_KeypadEnter: "⌤", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
    kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
    kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
    kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
  ]
}
