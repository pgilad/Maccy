import Foundation
import SQLite3

enum Schema {
  /// Each entry upgrades the schema by one version (`PRAGMA user_version`).
  static let migrations: [String] = [
    """
    CREATE TABLE items (
      -- AUTOINCREMENT: an ID is never used again, so late work (OCR, caches) for a
      -- deleted item cannot attach to a new one.
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      hash BLOB NOT NULL UNIQUE,
      kind INTEGER NOT NULL,
      title TEXT NOT NULL,
      body TEXT NOT NULL DEFAULT '',
      body_truncated INTEGER NOT NULL DEFAULT 0,
      ocr TEXT,
      app_bundle_id TEXT,
      app_name TEXT,
      first_copied_at REAL NOT NULL,
      last_copied_at REAL NOT NULL,
      copy_count INTEGER NOT NULL DEFAULT 1,
      pinned_at REAL,
      byte_size INTEGER NOT NULL DEFAULT 0,
      image_width INTEGER,
      image_height INTEGER,
      has_rich_text INTEGER NOT NULL DEFAULT 0,
      file_count INTEGER NOT NULL DEFAULT 0,
      sensitive INTEGER NOT NULL DEFAULT 0,
      expires_at REAL
    );
    CREATE INDEX items_recent ON items (last_copied_at DESC);
    CREATE INDEX items_kind_recent ON items (kind, last_copied_at DESC);
    CREATE INDEX items_pinned ON items (pinned_at) WHERE pinned_at IS NOT NULL;
    CREATE INDEX items_expires ON items (expires_at) WHERE expires_at IS NOT NULL;

    CREATE TABLE representations (
      item_id INTEGER NOT NULL REFERENCES items (id) ON DELETE CASCADE,
      item_index INTEGER NOT NULL,
      ordinal INTEGER NOT NULL,
      type TEXT NOT NULL,
      data BLOB,
      blob TEXT,
      size INTEGER NOT NULL,
      PRIMARY KEY (item_id, ordinal)
    ) WITHOUT ROWID;
    CREATE INDEX representations_blob ON representations (blob) WHERE blob IS NOT NULL;

    CREATE TABLE thumbnails (
      item_id INTEGER PRIMARY KEY REFERENCES items (id) ON DELETE CASCADE,
      data BLOB NOT NULL
    );

    CREATE VIRTUAL TABLE items_fts USING fts5 (
      title, body, ocr, app_name,
      content = 'items', content_rowid = 'id',
      tokenize = 'trigram remove_diacritics 1'
    );
    CREATE TRIGGER items_fts_insert AFTER INSERT ON items BEGIN
      INSERT INTO items_fts (rowid, title, body, ocr, app_name)
      VALUES (new.id, new.title, new.body, new.ocr, new.app_name);
    END;
    CREATE TRIGGER items_fts_delete AFTER DELETE ON items BEGIN
      INSERT INTO items_fts (items_fts, rowid, title, body, ocr, app_name)
      VALUES ('delete', old.id, old.title, old.body, old.ocr, old.app_name);
    END;
    CREATE TRIGGER items_fts_update AFTER UPDATE OF title, body, ocr, app_name ON items BEGIN
      INSERT INTO items_fts (items_fts, rowid, title, body, ocr, app_name)
      VALUES ('delete', old.id, old.title, old.body, old.ocr, old.app_name);
      INSERT INTO items_fts (rowid, title, body, ocr, app_name)
      VALUES (new.id, new.title, new.body, new.ocr, new.app_name);
    END;
    """
  ]

  static func migrate(_ database: SQLiteDatabase) throws {
    let version = try database.prepare("PRAGMA user_version").firstRow { $0.int(0) } ?? 0
    guard version < migrations.count else {
      return
    }
    try database.transaction {
      for (index, sql) in migrations.enumerated() where index >= version {
        try database.execute(sql)
      }
      try database.execute("PRAGMA user_version = \(migrations.count)")
    }
  }
}

/// `maccy_regexp(pattern, text)`: case-insensitive regular expression match.
/// The compiled expression is cached per statement with `sqlite3_set_auxdata`.
func registerFunctions(_ database: SQLiteDatabase) throws {
  let result = sqlite3_create_function_v2(
    database.handle, "maccy_regexp", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
    { context, argc, argv in
      guard argc == 2, let argv else {
        sqlite3_result_int(context, 0)
        return
      }
      var regex: NSRegularExpression?
      if let cached = sqlite3_get_auxdata(context, 0) {
        regex = Unmanaged<NSRegularExpression>.fromOpaque(cached).takeUnretainedValue()
      } else if let patternText = sqlite3_value_text(argv[0]) {
        let pattern = String(cString: patternText)
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
          sqlite3_result_error(context, "invalid regular expression", -1)
          return
        }
        regex = compiled
        sqlite3_set_auxdata(context, 0, Unmanaged.passRetained(compiled).toOpaque()) { pointer in
          if let pointer {
            Unmanaged<NSRegularExpression>.fromOpaque(pointer).release()
          }
        }
      }
      guard let regex, let text = sqlite3_value_text(argv[1]) else {
        sqlite3_result_int(context, 0)
        return
      }
      let string = String(cString: text)
      var found = false
      var cancelled = false
      // `.reportProgress` calls the block during long matches, so a slow pattern
      // (catastrophic backtracking) still stops when the search task is cancelled.
      regex.enumerateMatches(in: string, options: [.reportProgress], range: NSRange(string.startIndex..., in: string)) { match, _, stop in
        if match != nil {
          found = true
          stop.pointee = true
        } else if Task.isCancelled {
          cancelled = true
          stop.pointee = true
        }
      }
      if cancelled || Task.isCancelled {
        sqlite3_result_error_code(context, SQLITE_INTERRUPT)
        return
      }
      sqlite3_result_int(context, found ? 1 : 0)
    },
    nil, nil, nil
  )
  guard result == SQLITE_OK else {
    throw database.error(result)
  }
}
