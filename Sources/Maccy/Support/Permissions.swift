import AppKit
import ServiceManagement

enum Permissions {
  /// Needed to send ⌘V to other apps.
  static var accessibilityGranted: Bool { Paster.isTrusted }

  /// macOS 15.4 and later can ask the user before an app reads the pasteboard.
  /// A clipboard manager needs "always allow".
  static var pasteboardAccess: NSPasteboard.AccessBehavior { NSPasteboard.general.accessBehavior }

  static var pasteboardAccessDescription: String {
    switch pasteboardAccess {
    case .alwaysAllow: "Always allowed"
    case .ask: "Asks each time"
    case .alwaysDeny: "Denied"
    case .default: "Not asked yet"
    @unknown default: "Unknown"
    }
  }

  static var pasteboardAccessNeedsAttention: Bool {
    pasteboardAccess == .ask || pasteboardAccess == .alwaysDeny
  }

  static func openAccessibilitySettings() {
    open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
  }

  static func openPrivacySettings() {
    open("x-apple.systempreferences:com.apple.preference.security")
  }

  private static func open(_ string: String) {
    if let url = URL(string: string) {
      NSWorkspace.shared.open(url)
    }
  }
}

enum LaunchAtLogin {
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  static var needsApproval: Bool {
    SMAppService.mainApp.status == .requiresApproval
  }

  static func set(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      Log.app.error("Cannot change launch at login: \(error.localizedDescription, privacy: .public)")
    }
  }
}
