import AppKit

/// Application icons by bundle identifier. LaunchServices is asked once per app.
enum AppIcons {
  private static var cache: [String: NSImage] = [:]
  private static var missing: Set<String> = []

  static func icon(for bundleID: String?) -> NSImage? {
    guard let bundleID else {
      return nil
    }
    if let icon = cache[bundleID] {
      return icon
    }
    guard !missing.contains(bundleID) else {
      return nil
    }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      missing.insert(bundleID)
      return nil
    }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    cache[bundleID] = icon
    return icon
  }

  static func name(for bundleID: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return nil
    }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
  }
}
