import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
  public let code: Int32
  public let message: String

  public var description: String { "SQLite error \(code): \(message)" }
}

// SQLITE_TRANSIENT tells SQLite to copy bound buffers before the call returns.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A minimal wrapper around one SQLite connection.
/// It is not thread-safe. Its owner (an actor) must serialize all access.
final class SQLiteDatabase {
  private(set) var handle: OpaquePointer?
  private var statementCache: [String: Statement] = [:]

  init(path: String) throws {
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
    let result = sqlite3_open_v2(path, &handle, flags, nil)
    guard result == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
      sqlite3_close_v2(handle)
      handle = nil
      throw SQLiteError(code: result, message: message)
    }
    sqlite3_busy_timeout(handle, 2_000)
  }

  deinit {
    statementCache.removeAll()
    sqlite3_close_v2(handle)
  }

  var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
  var changes: Int { Int(sqlite3_changes(handle)) }

  func execute(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
    if result != SQLITE_OK {
      let message = errorMessage.map { String(cString: $0) } ?? "unknown"
      sqlite3_free(errorMessage)
      throw SQLiteError(code: result, message: message)
    }
  }

  /// Returns a cached prepared statement, reset and with cleared bindings.
  func prepare(_ sql: String) throws -> Statement {
    if let statement = statementCache[sql] {
      statement.reset()
      return statement
    }
    let statement = try Statement(database: self, sql: sql)
    // Search builds SQL with a variable number of conditions. Keep the cache small.
    if statementCache.count >= 128 {
      statementCache.removeAll()
    }
    statementCache[sql] = statement
    return statement
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  func error(_ code: Int32) -> SQLiteError {
    SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
  }
}

final class Statement {
  // Unowned: the database caches its statements, so a strong reference is a cycle.
  private unowned let database: SQLiteDatabase
  private var handle: OpaquePointer?

  init(database: SQLiteDatabase, sql: String) throws {
    self.database = database
    let result = sqlite3_prepare_v3(database.handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &handle, nil)
    guard result == SQLITE_OK else {
      throw database.error(result)
    }
  }

  deinit {
    sqlite3_finalize(handle)
  }

  func reset() {
    sqlite3_reset(handle)
    sqlite3_clear_bindings(handle)
  }

  @discardableResult
  func bind(_ values: SQLiteValue?...) throws -> Statement {
    try bind(values)
  }

  @discardableResult
  func bind(_ values: [SQLiteValue?]) throws -> Statement {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case nil:
        result = sqlite3_bind_null(handle, index)
      case .integer(let int)?:
        result = sqlite3_bind_int64(handle, index, int)
      case .real(let double)?:
        result = sqlite3_bind_double(handle, index, double)
      case .text(let string)?:
        // Pass the byte count, so text with an embedded NUL is stored in full.
        var copy = string
        result = copy.withUTF8 { buffer -> Int32 in
          guard let base = buffer.baseAddress else {
            return sqlite3_bind_text(handle, index, "", 0, SQLITE_TRANSIENT)
          }
          return base.withMemoryRebound(to: CChar.self, capacity: buffer.count) { pointer in
            sqlite3_bind_text64(handle, index, pointer, sqlite3_uint64(buffer.count), SQLITE_TRANSIENT, UInt8(SQLITE_UTF8))
          }
        }
      case .blob(let data)?:
        result = data.withUnsafeBytes { buffer in
          sqlite3_bind_blob64(handle, index, buffer.baseAddress, sqlite3_uint64(buffer.count), SQLITE_TRANSIENT)
        }
      }
      guard result == SQLITE_OK else {
        throw database.error(result)
      }
    }
    return self
  }

  /// Steps once. Returns `true` when a row is available.
  @discardableResult
  func step() throws -> Bool {
    let result = sqlite3_step(handle)
    switch result {
    case SQLITE_ROW:
      return true
    case SQLITE_DONE:
      return false
    default:
      throw database.error(result)
    }
  }

  // The helpers below reset the statement when they finish. An active statement
  // keeps a read transaction open, and that blocks WAL checkpoints.

  func run() throws {
    defer { sqlite3_reset(handle) }
    while try step() {}
  }

  func rows<T>(_ transform: (Row) throws -> T) throws -> [T] {
    defer { sqlite3_reset(handle) }
    var output: [T] = []
    let row = Row(handle: handle)
    while try step() {
      output.append(try transform(row))
    }
    return output
  }

  func firstRow<T>(_ transform: (Row) throws -> T) throws -> T? {
    defer { sqlite3_reset(handle) }
    guard try step() else {
      return nil
    }
    return try transform(Row(handle: handle))
  }
}

struct Row {
  let handle: OpaquePointer?

  func isNull(_ index: Int32) -> Bool {
    sqlite3_column_type(handle, index) == SQLITE_NULL
  }

  func int64(_ index: Int32) -> Int64 {
    sqlite3_column_int64(handle, index)
  }

  func int(_ index: Int32) -> Int {
    Int(sqlite3_column_int64(handle, index))
  }

  func optionalInt(_ index: Int32) -> Int? {
    isNull(index) ? nil : int(index)
  }

  func double(_ index: Int32) -> Double {
    sqlite3_column_double(handle, index)
  }

  func optionalDouble(_ index: Int32) -> Double? {
    isNull(index) ? nil : double(index)
  }

  func date(_ index: Int32) -> Date {
    Date(timeIntervalSince1970: double(index))
  }

  func optionalDate(_ index: Int32) -> Date? {
    optionalDouble(index).map(Date.init(timeIntervalSince1970:))
  }

  func string(_ index: Int32) -> String {
    guard let text = sqlite3_column_text(handle, index) else {
      return ""
    }
    let count = Int(sqlite3_column_bytes(handle, index))
    return String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
  }

  func optionalString(_ index: Int32) -> String? {
    isNull(index) ? nil : string(index)
  }

  func data(_ index: Int32) -> Data? {
    guard let bytes = sqlite3_column_blob(handle, index) else {
      return isNull(index) ? nil : Data()
    }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, index)))
  }
}

enum SQLiteValue {
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob(Data)

  static func int(_ value: Int) -> SQLiteValue { .integer(Int64(value)) }
  static func date(_ value: Date) -> SQLiteValue { .real(value.timeIntervalSince1970) }
  static func bool(_ value: Bool) -> SQLiteValue { .integer(value ? 1 : 0) }
}
