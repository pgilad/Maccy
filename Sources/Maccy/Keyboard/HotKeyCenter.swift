import AppKit
import Carbon

/// Registers the global shortcut with the Carbon hot key API. This API needs
/// no Accessibility or Input Monitoring permission.
final class HotKeyCenter {
  static let shared = HotKeyCenter()

  var onPress: (() -> Void)?

  private var combo: KeyCombo?
  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private var suspendCount = 0
  private static let signature: OSType = 0x4D_41_43_43 // "MACC"

  private init() {}

  func register(_ combo: KeyCombo?) {
    self.combo = combo
    apply()
  }

  /// Stops the shortcut, for example while the user records a new one.
  func suspend() {
    suspendCount += 1
    apply()
  }

  func resume() {
    suspendCount = max(0, suspendCount - 1)
    apply()
  }

  private func apply() {
    unregisterCurrent()
    guard suspendCount == 0, let combo else {
      return
    }
    installHandlerIfNeeded()
    let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
    let status = RegisterEventHotKey(
      UInt32(combo.keyCode), combo.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
    )
    if status != noErr {
      Log.hotKey.error("Cannot register the global shortcut, status \(status, privacy: .public)")
      hotKeyRef = nil
    }
  }

  private func unregisterCurrent() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
    hotKeyRef = nil
  }

  private func installHandlerIfNeeded() {
    guard handlerRef == nil else {
      return
    }
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
      var hotKeyID = EventHotKeyID()
      GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
      )
      guard hotKeyID.signature == HotKeyCenter.signature else {
        return OSStatus(eventNotHandledErr)
      }
      // Carbon delivers application events on the main thread.
      MainActor.assumeIsolated {
        HotKeyCenter.shared.onPress?()
      }
      return noErr
    }, 1, &eventType, nil, &handlerRef)
  }
}
