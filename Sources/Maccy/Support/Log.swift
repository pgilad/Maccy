import OSLog

/// Unified logging. Clipboard content must never appear in a log message:
/// interpolate IDs and counts only, or mark values `privacy: .private`.
nonisolated enum Log {
  static let app = Logger(subsystem: "com.giladpeleg.maccy", category: "app")
  static let capture = Logger(subsystem: "com.giladpeleg.maccy", category: "capture")
  static let history = Logger(subsystem: "com.giladpeleg.maccy", category: "history")
  static let hotKey = Logger(subsystem: "com.giladpeleg.maccy", category: "hotkey")
}
