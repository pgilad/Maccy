import AppKit
import ApplicationServices

/// Sends ⌘V to the frontmost application. This needs the Accessibility permission.
enum Paster {
  static var isTrusted: Bool { AXIsProcessTrusted() }

  /// Shows the system prompt that asks for Accessibility access.
  static func requestAccess() {
    // The value of kAXTrustedCheckOptionPrompt. The global is not concurrency-safe in Swift 6.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  /// Returns `false` when the permission is missing. Then nothing is sent.
  @discardableResult
  static func paste() -> Bool {
    guard isTrusted else {
      return false
    }
    let keyCode = KeyboardLayout.pasteKeyCode
    // 0x000008 marks the left ⌘ key as down. Some apps check the device-dependent flag.
    let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
    let source = CGEventSource(stateID: .combinedSessionState)
    // Ignore the physical keyboard while the synthetic keystroke is in flight.
    source?.setLocalEventsFilterDuringSuppressionState(
      [.permitLocalMouseEvents, .permitSystemDefinedEvents],
      state: .eventSuppressionStateSuppressionInterval
    )
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    keyDown?.flags = flags
    keyUp?.flags = flags
    keyDown?.post(tap: .cgSessionEventTap)
    keyUp?.post(tap: .cgSessionEventTap)
    return true
  }
}
