import AppKit
import Carbon

/// Maps virtual key codes to characters for the current keyboard layout.
/// The Text Input Source APIs require the main thread.
enum KeyboardLayout {
  /// Layouts such as "Dvorak - QWERTY ⌘" switch to QWERTY while ⌘ is down.
  static var commandSwitchesToQWERTY: Bool {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
      return false
    }
    let name = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    return name.hasSuffix("⌘")
  }

  /// The character that the key types with no modifiers, or `nil` for keys without one.
  static func character(forKeyCode keyCode: UInt16) -> String? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
      return nil
    }
    let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    var deadKeyState: UInt32 = 0
    var length = 0
    var characters = [UniChar](repeating: 0, count: 4)
    let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
      guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
        return OSStatus(paramErr)
      }
      return UCKeyTranslate(
        layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
      )
    }
    guard status == noErr, length > 0 else {
      return nil
    }
    let string = String(utf16CodeUnits: characters, count: length)
    return string.trimmingCharacters(in: .controlCharacters).isEmpty ? nil : string
  }

  /// The key code that types `character` in the current layout.
  static func keyCode(for character: String) -> UInt16? {
    let target = character.lowercased()
    return (0..<128).map(UInt16.init).first { self.character(forKeyCode: $0)?.lowercased() == target }
  }

  /// The key code to post for ⌘V.
  static var pasteKeyCode: CGKeyCode {
    if commandSwitchesToQWERTY {
      return CGKeyCode(kVK_ANSI_V)
    }
    return keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
  }
}
