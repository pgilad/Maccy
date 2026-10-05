import Foundation

nonisolated enum Paths {
  /// `Application Support/Maccy`. Inside the App Sandbox this is in the app container.
  /// Debug builds accept `MACCY_DATA_DIR`, so tests and self-tests do not touch real data.
  static var dataDirectory: URL {
    #if DEBUG
    if let override = ProcessInfo.processInfo.environment["MACCY_DATA_DIR"], !override.isEmpty {
      return URL(filePath: override, directoryHint: .isDirectory)
    }
    #endif
    return URL.applicationSupportDirectory.appending(path: "Maccy", directoryHint: .isDirectory)
  }
}
