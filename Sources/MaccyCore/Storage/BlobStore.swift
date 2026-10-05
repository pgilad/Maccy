import CryptoKit
import Foundation

/// Content-addressed files for large representations: `blobs/ab/abcdef…`.
struct BlobStore {
  let directory: URL

  init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  static func key(for data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func url(for key: String) -> URL {
    directory.appending(path: String(key.prefix(2)), directoryHint: .isDirectory).appending(path: key)
  }

  /// Writes the data once. The same content always maps to the same file.
  func write(_ data: Data) throws -> String {
    let key = Self.key(for: data)
    let url = url(for: key)
    if !FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    }
    return key
  }

  func read(_ key: String) -> Data? {
    try? Data(contentsOf: url(for: key), options: .mappedIfSafe)
  }

  func delete(_ key: String) {
    try? FileManager.default.removeItem(at: url(for: key))
  }

  /// All keys on disk. The garbage collector compares them with the database.
  func allKeys() -> [String] {
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    var keys: [String] = []
    for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
      keys.append(url.lastPathComponent)
    }
    return keys
  }
}
