import Foundation
import OSLog
import SQLite3

public struct RetentionPolicy: Sendable, Equatable {
  /// Unpinned items older than this are deleted. `nil` keeps items forever.
  public var maxAge: TimeInterval?
  /// The maximum number of unpinned items. `nil` means no limit.
  public var maxItems: Int?
  /// The maximum total size of unpinned items. `nil` means no limit.
  public var maxTotalBytes: Int?

  public init(maxAge: TimeInterval? = nil, maxItems: Int? = nil, maxTotalBytes: Int? = nil) {
    self.maxAge = maxAge
    self.maxItems = maxItems
    self.maxTotalBytes = maxTotalBytes
  }
}

public struct UpsertResult: Sendable, Equatable {
  public let id: Int64
  public let isNew: Bool
}

public struct HistoryStats: Sendable, Equatable {
  public var itemCount: Int
  public var pinnedCount: Int
  public var contentBytes: Int
  public var diskBytes: Int
}

public enum SearchResponse: Sendable, Equatable {
  case hits([SearchHit])
  case invalidRegex(String)

  public var hits: [SearchHit] {
    if case .hits(let hits) = self {
      return hits
    }
    return []
  }
}

/// The clipboard history database: SQLite (WAL) for rows and the FTS5 index,
/// and content-addressed files for large representations.
public actor HistoryStore {
  public static let databaseFileName = "history.sqlite"
  /// Representations larger than this go to a file, not into SQLite.
  static let inlineLimit = 32 * 1_024
  static let candidateLimit = 1_000
  static let titleCandidateLimit = 300
  /// The ranker reads this many characters of the body and OCR text.
  static let rankedPrefixLength = 1_000
  static let fuzzyScanLimit = 5_000

  public nonisolated let directory: URL
  private let database: SQLiteDatabase
  private let blobs: BlobStore
  private let logger = Logger(subsystem: "com.pgilad.Maccy", category: "store")

  private static let summaryColumns = """
    items.id, items.kind, items.title, items.app_bundle_id, items.app_name, items.first_copied_at,
    items.last_copied_at, items.copy_count, items.pinned_at, items.byte_size, items.image_width,
    items.image_height, items.has_rich_text, items.file_count, items.sensitive, items.expires_at
    """

  /// Opens the store. A damaged database file is moved aside and a new, empty
  /// store starts, so a bad file never blocks the app. Other errors (a busy lock,
  /// a full disk) are thrown, and the file stays in place.
  public init(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var resourceValues = URLResourceValues()
    // Clipboard history can contain secrets. Keep it out of Time Machine backups.
    resourceValues.isExcludedFromBackup = true
    var mutableDirectory = directory
    try? mutableDirectory.setResourceValues(resourceValues)

    let path = directory.appending(path: Self.databaseFileName).path
    let database: SQLiteDatabase
    do {
      database = try Self.openAndMigrate(path: path)
    } catch let error as SQLiteError where error.isDamagedFile {
      Logger(subsystem: "com.pgilad.Maccy", category: "store")
        .error("Cannot open the database, moving it aside: \(String(describing: error), privacy: .public)")
      let suffix = ".corrupt-\(Int(Date.now.timeIntervalSince1970))"
      for extra in ["", "-wal", "-shm"] {
        try? FileManager.default.moveItem(atPath: path + extra, toPath: path + suffix + extra)
      }
      database = try Self.openAndMigrate(path: path)
    }
    self.directory = directory
    self.database = database
    self.blobs = try BlobStore(directory: directory.appending(path: "blobs", directoryHint: .isDirectory))
  }

  private static func openAndMigrate(path: String) throws -> SQLiteDatabase {
    let database = try SQLiteDatabase(path: path)
    try database.execute("""
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      PRAGMA foreign_keys = ON;
      PRAGMA secure_delete = ON;
      PRAGMA temp_store = MEMORY;
      """)
    try registerFunctions(database)
    // Long queries (a regex over every item) stop when the calling task is cancelled.
    // SQLite then returns SQLITE_INTERRUPT. Each statement is atomic, so no data is lost.
    sqlite3_progress_handler(database.handle, 1_000, { _ in Task.isCancelled ? 1 : 0 }, nil)
    try Schema.migrate(database)
    // Fail early on a damaged file instead of at the first query.
    let result = try database.prepare("PRAGMA quick_check").firstRow { $0.string(0) }
    guard result == "ok" else {
      throw SQLiteError(code: SQLITE_CORRUPT, message: result ?? "quick_check failed")
    }
    return database
  }

  // MARK: - Writes

  @discardableResult
  public func upsert(_ clip: AnalyzedClip, thumbnail: Data?, expiresAt: Date?) throws -> UpsertResult {
    var orphanCandidates: [String] = []
    let result = try database.transaction {
      try upsertRow(clip, thumbnail: thumbnail, expiresAt: expiresAt, orphanCandidates: &orphanCandidates)
    }
    try deleteUnreferencedBlobs(orphanCandidates)
    return result
  }

  /// Inserts many items in one transaction (import and performance tests).
  public func upsert(batch clips: [AnalyzedClip]) throws {
    var orphanCandidates: [String] = []
    try database.transaction {
      for clip in clips {
        _ = try upsertRow(clip, thumbnail: nil, expiresAt: nil, orphanCandidates: &orphanCandidates)
      }
    }
    try deleteUnreferencedBlobs(orphanCandidates)
  }

  private func upsertRow(
    _ clip: AnalyzedClip,
    thumbnail: Data?,
    expiresAt: Date?,
    orphanCandidates: inout [String]
  ) throws -> UpsertResult {
    let now = clip.capturedAt
    var keptRepresentations: [StoredRepresentation] = []
    let find = try database.prepare("SELECT id, pinned_at FROM items WHERE hash = ?")
    try find.bind(.blob(clip.contentHash))
    let existing = try find.firstRow { (id: $0.int64(0), isPinned: !$0.isNull(1)) }

    let id: Int64
    if let existing {
      id = existing.id
      try database.prepare("""
        UPDATE items SET last_copied_at = ?, copy_count = copy_count + 1, byte_size = ?,
          image_width = ?, image_height = ?, has_rich_text = ?, file_count = ?,
          sensitive = ?, expires_at = ?
        WHERE id = ?
        """)
        .bind(
          .date(now), .int(clip.byteSize), clip.imageWidth.map(SQLiteValue.int),
          clip.imageHeight.map(SQLiteValue.int), .bool(clip.hasRichText), .int(clip.fileCount),
          .bool(clip.detectedSecret != nil), existing.isPinned ? nil : expiresAt.map(SQLiteValue.date),
          .integer(id)
        )
        .run()
      // Update the source app only when it changed, so the FTS row is rebuilt only then.
      if clip.sourceBundleID != nil || clip.sourceAppName != nil {
        try database.prepare("""
          UPDATE items SET app_bundle_id = ?, app_name = ?
          WHERE id = ? AND (app_bundle_id IS NOT ? OR app_name IS NOT ?)
          """)
          .bind(
            clip.sourceBundleID.map(SQLiteValue.text), clip.sourceAppName.map(SQLiteValue.text),
            .integer(id),
            clip.sourceBundleID.map(SQLiteValue.text), clip.sourceAppName.map(SQLiteValue.text)
          )
          .run()
      }
      // Keep old representations that the new copy lacks, for example the
      // formatting of an earlier copy of the same text. New data wins per type.
      let newKeys = Set(clip.representations.map { RepresentationKey(itemIndex: $0.itemIndex, type: $0.type) })
      keptRepresentations = try database.prepare("""
        SELECT item_index, type, data, blob, size FROM representations WHERE item_id = ? ORDER BY ordinal
        """)
        .bind(.integer(id))
        .rows {
          StoredRepresentation(itemIndex: $0.int(0), type: $0.string(1), data: $0.data(2), blob: $0.optionalString(3), size: $0.int(4))
        }
        .filter { !newKeys.contains(RepresentationKey(itemIndex: $0.itemIndex, type: $0.type)) }
      orphanCandidates += try blobKeys(itemID: id)
      try database.prepare("DELETE FROM representations WHERE item_id = ?").bind(.integer(id)).run()
    } else {
      try database.prepare("""
        INSERT INTO items (hash, kind, title, body, body_truncated, app_bundle_id, app_name,
          first_copied_at, last_copied_at, byte_size, image_width, image_height, has_rich_text,
          file_count, sensitive, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        .bind(
          .blob(clip.contentHash), .int(clip.kind.rawValue), .text(clip.title), .text(clip.text),
          .bool(clip.isTextTruncated), clip.sourceBundleID.map(SQLiteValue.text),
          clip.sourceAppName.map(SQLiteValue.text), .date(now), .date(now), .int(clip.byteSize),
          clip.imageWidth.map(SQLiteValue.int), clip.imageHeight.map(SQLiteValue.int),
          .bool(clip.hasRichText), .int(clip.fileCount), .bool(clip.detectedSecret != nil),
          expiresAt.map(SQLiteValue.date)
        )
        .run()
      id = database.lastInsertRowID
    }

    try insertRepresentations(clip.representations, itemID: id)
    if !keptRepresentations.isEmpty {
      let insert = try database.prepare("""
        INSERT INTO representations (item_id, item_index, ordinal, type, data, blob, size) VALUES (?, ?, ?, ?, ?, ?, ?)
        """)
      for (offset, kept) in keptRepresentations.enumerated() {
        try insert.bind(
          .integer(id), .int(kept.itemIndex), .int(clip.representations.count + offset), .text(kept.type),
          kept.data.map(SQLiteValue.blob), kept.blob.map(SQLiteValue.text), .int(kept.size)
        )
        try insert.run()
      }
      try database.prepare("""
        UPDATE items SET
          byte_size = (SELECT COALESCE(SUM(size), 0) FROM representations WHERE item_id = ?1),
          has_rich_text = (kind = 0 AND EXISTS (
            SELECT 1 FROM representations WHERE item_id = ?1 AND type IN ('\(PasteboardTypes.rtf)', '\(PasteboardTypes.html)')))
        WHERE id = ?1
        """)
        .bind(.integer(id))
        .run()
    }
    if let thumbnail {
      try database.prepare("INSERT OR REPLACE INTO thumbnails (item_id, data) VALUES (?, ?)")
        .bind(.integer(id), .blob(thumbnail))
        .run()
    }
    return UpsertResult(id: id, isNew: existing == nil)
  }

  private func insertRepresentations(_ representations: [Representation], itemID: Int64) throws {
    let insert = try database.prepare("""
      INSERT OR REPLACE INTO representations (item_id, item_index, ordinal, type, data, blob, size)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """)
    for (ordinal, representation) in representations.enumerated() {
      insert.reset()
      var inline: Data? = representation.data
      var blobKey: String?
      if representation.data.count > Self.inlineLimit {
        blobKey = try blobs.write(representation.data)
        inline = nil
      }
      try insert.bind(
        .integer(itemID), .int(representation.itemIndex), .int(ordinal), .text(representation.type),
        inline.map(SQLiteValue.blob), blobKey.map(SQLiteValue.text), .int(representation.data.count)
      )
      try insert.run()
    }
  }

  /// Moves an item to the top, for example after Maccy pasted it.
  public func touch(id: Int64, at date: Date = .now) throws {
    try database.prepare("UPDATE items SET last_copied_at = ?, copy_count = copy_count + 1 WHERE id = ?")
      .bind(.date(date), .integer(id))
      .run()
  }

  /// Pins or unpins an item. A pinned item never expires.
  public func setPinned(id: Int64, _ pinned: Bool, at date: Date = .now) throws {
    if pinned {
      try database.prepare("UPDATE items SET pinned_at = ?, expires_at = NULL WHERE id = ? AND pinned_at IS NULL")
        .bind(.date(date), .integer(id))
        .run()
    } else {
      try database.prepare("UPDATE items SET pinned_at = NULL WHERE id = ?").bind(.integer(id)).run()
    }
  }

  public func setOCRText(id: Int64, text: String) throws {
    try database.prepare("UPDATE items SET ocr = ? WHERE id = ?")
      .bind(.text(String(text.prefix(ClipAnalyzer.maxIndexedTextLength))), .integer(id))
      .run()
  }

  @discardableResult
  public func delete(ids: [Int64]) throws -> Int {
    guard !ids.isEmpty else {
      return 0
    }
    let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
    return try deleteItems(where: "items.id IN (\(placeholders))", bindings: ids.map { .integer($0) })
  }

  @discardableResult
  public func deleteAll(keepPinned: Bool) throws -> Int {
    let deleted = try deleteItems(where: keepPinned ? "items.pinned_at IS NULL" : "1", bindings: [])
    // Remove deleted content from the write-ahead log too.
    try? database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    return deleted
  }

  /// Deletes expired items and applies the retention policy. Pinned items stay.
  @discardableResult
  public func prune(policy: RetentionPolicy, now: Date = .now) throws -> Int {
    var deleted = try deleteItems(
      where: "items.pinned_at IS NULL AND items.expires_at IS NOT NULL AND items.expires_at <= ?",
      bindings: [.date(now)]
    )

    if let maxAge = policy.maxAge {
      deleted += try deleteItems(
        where: "items.pinned_at IS NULL AND items.last_copied_at < ?",
        bindings: [.date(now.addingTimeInterval(-maxAge))]
      )
    }

    if let maxItems = policy.maxItems {
      deleted += try deleteItems(
        where: """
          items.pinned_at IS NULL AND items.id NOT IN (
            SELECT id FROM items WHERE pinned_at IS NULL ORDER BY last_copied_at DESC LIMIT ?)
          """,
        bindings: [.int(max(0, maxItems))]
      )
    }

    if let maxTotalBytes = policy.maxTotalBytes {
      let rows = try database.prepare("""
        SELECT id, byte_size FROM items WHERE pinned_at IS NULL ORDER BY last_copied_at DESC
        """)
        .rows { (id: $0.int64(0), size: $0.int(1)) }
      var total = 0
      var overflow: [Int64] = []
      for (index, row) in rows.enumerated() {
        total += row.size
        // Never delete the newest item, even when it alone is over the limit.
        if index > 0 && total > maxTotalBytes {
          overflow.append(row.id)
        }
      }
      for chunk in overflow.chunked(into: 500) {
        deleted += try delete(ids: chunk)
      }
    }

    if deleted > 0 {
      try? database.execute("PRAGMA wal_checkpoint(PASSIVE)")
    }
    return deleted
  }

  /// The next time an item expires, so the caller can schedule the next prune.
  public func nextExpiry() throws -> Date? {
    try database.prepare("SELECT MIN(expires_at) FROM items WHERE expires_at IS NOT NULL AND pinned_at IS NULL")
      .firstRow { $0.optionalDate(0) } ?? nil
  }

  private func deleteItems(where condition: String, bindings: [SQLiteValue]) throws -> Int {
    let keys = try database.prepare("""
      SELECT DISTINCT representations.blob FROM representations
      JOIN items ON items.id = representations.item_id
      WHERE representations.blob IS NOT NULL AND \(condition)
      """)
      .bind(bindings)
      .rows { $0.string(0) }
    try database.prepare("DELETE FROM items WHERE \(condition)").bind(bindings).run()
    let deleted = database.changes
    try deleteUnreferencedBlobs(keys)
    return deleted
  }

  private func blobKeys(itemID: Int64) throws -> [String] {
    try database.prepare("SELECT blob FROM representations WHERE item_id = ? AND blob IS NOT NULL")
      .bind(.integer(itemID))
      .rows { $0.string(0) }
  }

  private func deleteUnreferencedBlobs(_ keys: [String]) throws {
    guard !keys.isEmpty else {
      return
    }
    let check = try database.prepare("SELECT 1 FROM representations WHERE blob = ? LIMIT 1")
    for key in Set(keys) {
      check.reset()
      if try check.bind(.text(key)).firstRow({ _ in true }) == nil {
        blobs.delete(key)
      }
    }
  }

  /// Deletes blob files that no row references (for example after a crash).
  @discardableResult
  public func collectGarbage() throws -> Int {
    let referenced = Set(try database.prepare("SELECT DISTINCT blob FROM representations WHERE blob IS NOT NULL")
      .rows { $0.string(0) })
    var removed = 0
    for key in blobs.allKeys() where !referenced.contains(key) {
      blobs.delete(key)
      removed += 1
    }
    return removed
  }

  // MARK: - Reads

  /// Pinned items first (in pin order), then the most recent items.
  public func recent(kind: ClipKind? = nil, limit: Int) throws -> [ClipSummary] {
    let kindCondition = kind == nil ? "" : "AND kind = ?"
    let kindBinding: [SQLiteValue] = kind.map { [.int($0.rawValue)] } ?? []
    let pinned = try database.prepare("""
      SELECT \(Self.summaryColumns) FROM items WHERE pinned_at IS NOT NULL \(kindCondition) ORDER BY pinned_at
      """)
      .bind(kindBinding)
      .rows(Self.summary)
    let unpinned = try database.prepare("""
      SELECT \(Self.summaryColumns) FROM items WHERE pinned_at IS NULL \(kindCondition)
      ORDER BY last_copied_at DESC LIMIT ?
      """)
      .bind(kindBinding + [.int(max(0, limit - pinned.count))])
      .rows(Self.summary)
    return pinned + unpinned
  }

  /// The most recent unpinned item, for the menu bar title.
  public func latestUnpinned() throws -> ClipSummary? {
    try database.prepare("SELECT \(Self.summaryColumns) FROM items WHERE pinned_at IS NULL ORDER BY last_copied_at DESC LIMIT 1")
      .firstRow(Self.summary)
  }

  public func summary(id: Int64) throws -> ClipSummary? {
    try database.prepare("SELECT \(Self.summaryColumns) FROM items WHERE id = ?")
      .bind(.integer(id))
      .firstRow(Self.summary)
  }

  public func search(_ query: SearchQuery, limit: Int, now: Date = .now) throws -> SearchResponse {
    try Task.checkCancellation()
    if let pattern = query.regex {
      guard (try? NSRegularExpression(pattern: pattern)) != nil else {
        return .invalidRegex(pattern)
      }
      return .hits(try regexSearch(pattern, query: query, limit: limit))
    }

    guard !query.terms.isEmpty else {
      return .hits(try filteredRecent(query, limit: limit))
    }

    var conditions: [String] = []
    var bindings: [SQLiteValue] = []
    let ftsTerms = query.terms.filter { $0.count >= 3 }
    // The trigram index needs at least three characters. Shorter terms scan with
    // maccy_contains, which folds case and diacritics like the index. LIKE folds
    // ASCII case only, so "ü" did not find "Über".
    for term in query.terms where term.count < 3 {
      conditions.append("""
        (maccy_contains(items.title, ?) OR maccy_contains(items.body, ?)
          OR maccy_contains(items.ocr, ?) OR maccy_contains(items.app_name, ?))
        """)
      bindings += Array(repeating: .text(term), count: 4)
    }
    appendFilters(query, to: &conditions, bindings: &bindings)

    // Phase 1: candidate IDs only, so the sort does not carry row data.
    // The most recent matches anywhere, plus the most recent title matches,
    // so a strong but old title match is not lost.
    var candidateIDs: [Int64] = []
    var seen = Set<Int64>()
    let phases: [(column: String?, limit: Int)] = ftsTerms.isEmpty
      ? [(nil, Self.candidateLimit)]
      : [(nil, Self.candidateLimit), ("title", Self.titleCandidateLimit)]
    for (index, phase) in phases.enumerated() {
      // When the first phase found fewer than its limit, it already has every match.
      if index > 0 && candidateIDs.count < Self.candidateLimit {
        break
      }
      try Task.checkCancellation()
      var phaseConditions = conditions
      var phaseBindings = bindings
      var from = "items"
      if !ftsTerms.isEmpty {
        from = "items_fts JOIN items ON items.id = items_fts.rowid"
        phaseConditions.insert("items_fts MATCH ?", at: 0)
        phaseBindings.insert(.text(Self.matchExpression(ftsTerms, column: phase.column)), at: 0)
      }
      let ids = try database.prepare("""
        SELECT items.id FROM \(from)
        WHERE \(phaseConditions.isEmpty ? "1" : phaseConditions.joined(separator: " AND "))
        ORDER BY items.last_copied_at DESC LIMIT \(phase.limit)
        """)
        .bind(phaseBindings)
        .rows { $0.int64(0) }
      for id in ids where seen.insert(id).inserted {
        candidateIDs.append(id)
      }
    }

    // Phase 2: row data for the candidates, then rank in Swift.
    var candidates: [Ranker.Candidate] = []
    candidates.reserveCapacity(candidateIDs.count)
    for chunk in candidateIDs.chunked(into: 500) {
      try Task.checkCancellation()
      let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
      candidates += try database.prepare("""
        SELECT \(Self.summaryColumns), substr(items.body, 1, \(Self.rankedPrefixLength)),
          substr(items.ocr, 1, \(Self.rankedPrefixLength))
        FROM items WHERE items.id IN (\(placeholders))
        """)
        .bind(chunk.map { .integer($0) })
        .rows { row in
          Ranker.Candidate(summary: Self.summary(row), bodyPrefix: row.string(16), ocrPrefix: row.string(17))
        }
    }

    if !candidates.isEmpty {
      return .hits(Array(Ranker.rank(candidates, terms: query.terms, now: now).prefix(limit)))
    }

    try Task.checkCancellation()
    return .hits(try fuzzySearch(query, limit: limit))
  }

  /// An FTS5 expression: each term is a quoted string, and all terms must match.
  static func matchExpression(_ terms: [String], column: String?) -> String {
    let quoted = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " ")
    return column.map { "\($0) : (\(quoted))" } ?? quoted
  }

  private func filteredRecent(_ query: SearchQuery, limit: Int) throws -> [SearchHit] {
    var conditions = ["1"]
    var bindings: [SQLiteValue] = []
    appendFilters(query, to: &conditions, bindings: &bindings)
    return try database.prepare("""
      SELECT \(Self.summaryColumns) FROM items WHERE \(conditions.joined(separator: " AND "))
      ORDER BY items.pinned_at IS NULL, items.pinned_at, items.last_copied_at DESC LIMIT ?
      """)
      .bind(bindings + [.int(limit)])
      .rows { SearchHit(summary: Self.summary($0)) }
  }

  private func fuzzySearch(_ query: SearchQuery, limit: Int) throws -> [SearchHit] {
    let pattern = query.terms.joined()
    guard pattern.count >= 2 else {
      return []
    }
    var conditions = ["1"]
    var bindings: [SQLiteValue] = []
    appendFilters(query, to: &conditions, bindings: &bindings)
    let rows = try database.prepare("""
      SELECT \(Self.summaryColumns) FROM items WHERE \(conditions.joined(separator: " AND "))
      ORDER BY items.last_copied_at DESC LIMIT \(Self.fuzzyScanLimit)
      """)
      .bind(bindings)
      .rows(Self.summary)
    return rows
      .compactMap { summary -> SearchHit? in
        guard let match = FuzzyMatcher.match(pattern, in: summary.title) else {
          return nil
        }
        return SearchHit(summary: summary, titleMatches: FuzzyMatcher.ranges(from: match.positions), score: match.score)
      }
      .sorted { $0.score > $1.score }
      .prefix(limit)
      .map { $0 }
  }

  private func regexSearch(_ pattern: String, query: SearchQuery, limit: Int) throws -> [SearchHit] {
    var conditions = ["(maccy_regexp(?, items.title) OR maccy_regexp(?, items.body) OR maccy_regexp(?, items.ocr))"]
    var bindings: [SQLiteValue] = [.text(pattern), .text(pattern), .text(pattern)]
    appendFilters(query, to: &conditions, bindings: &bindings)
    let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    return try database.prepare("""
      SELECT \(Self.summaryColumns) FROM items WHERE \(conditions.joined(separator: " AND "))
      ORDER BY items.last_copied_at DESC LIMIT ?
      """)
      .bind(bindings + [.int(limit)])
      .rows { row in
        let summary = Self.summary(row)
        let title = summary.title
        let matches = regex.matches(in: title, range: NSRange(title.startIndex..., in: title))
          .compactMap { Range($0.range, in: title) }
          .map { Ranker.characterOffsets(of: $0, in: title) }
        return SearchHit(summary: summary, titleMatches: matches)
      }
  }

  private func appendFilters(_ query: SearchQuery, to conditions: inout [String], bindings: inout [SQLiteValue]) {
    if let kind = query.kind {
      conditions.append("items.kind = ?")
      bindings.append(.int(kind.rawValue))
    }
    if let app = query.app {
      conditions.append("(maccy_contains(items.app_name, ?) OR maccy_contains(items.app_bundle_id, ?))")
      bindings += [.text(app), .text(app)]
    }
    if query.pinnedOnly {
      conditions.append("items.pinned_at IS NOT NULL")
    }
  }

  public func detail(id: Int64) throws -> ClipDetail? {
    guard let row = try database.prepare("""
      SELECT \(Self.summaryColumns), items.body, items.body_truncated, items.ocr FROM items WHERE id = ?
      """)
      .bind(.integer(id))
      .firstRow({ (summary: Self.summary($0), body: $0.string(16), truncated: $0.int(17) != 0, ocr: $0.optionalString(18)) })
    else {
      return nil
    }
    let types = try database.prepare("SELECT type, data, blob FROM representations WHERE item_id = ? ORDER BY ordinal")
      .bind(.integer(id))
      .rows { (type: $0.string(0), data: $0.data(1), blob: $0.optionalString(2)) }
    let fileURLs = types
      .filter { $0.type == PasteboardTypes.fileURL }
      .compactMap { $0.data.flatMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) } }
    var seen = Set<String>()
    return ClipDetail(
      summary: row.summary,
      text: row.body,
      isTextTruncated: row.truncated,
      ocrText: row.ocr,
      fileURLs: fileURLs,
      representationTypes: types.map(\.type).filter { seen.insert($0).inserted }
    )
  }

  /// All representations with their data, in pasteboard order.
  public func representations(id: Int64) throws -> [Representation] {
    try database.prepare("SELECT item_index, type, data, blob FROM representations WHERE item_id = ? ORDER BY ordinal")
      .bind(.integer(id))
      .rows { row -> Representation? in
        let data = row.data(2) ?? row.optionalString(3).flatMap { blobs.read($0) }
        return data.map { Representation(itemIndex: row.int(0), type: row.string(1), data: $0) }
      }
      .compactMap { $0 }
  }

  public func imageData(id: Int64) throws -> Data? {
    let placeholders = PasteboardTypes.images.map { _ in "?" }.joined(separator: ",")
    return try database.prepare("""
      SELECT data, blob FROM representations WHERE item_id = ? AND type IN (\(placeholders)) LIMIT 1
      """)
      .bind([.integer(id)] + PasteboardTypes.images.map { .text($0) })
      .firstRow { row in row.data(0) ?? row.optionalString(1).flatMap { blobs.read($0) } } ?? nil
  }

  public func thumbnail(id: Int64) throws -> Data? {
    try database.prepare("SELECT data FROM thumbnails WHERE item_id = ?")
      .bind(.integer(id))
      .firstRow { $0.data(0) } ?? nil
  }

  public func stats() throws -> HistoryStats {
    let counts = try database.prepare("""
      SELECT COUNT(*), COUNT(pinned_at), COALESCE(SUM(byte_size), 0) FROM items
      """)
      .firstRow { (items: $0.int(0), pinned: $0.int(1), bytes: $0.int(2)) } ?? (items: 0, pinned: 0, bytes: 0)
    return HistoryStats(itemCount: counts.items, pinnedCount: counts.pinned, contentBytes: counts.bytes, diskBytes: diskSize())
  }

  private func diskSize() -> Int {
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
    ) else {
      return 0
    }
    var total = 0
    for case let url as URL in enumerator {
      total += (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
    }
    return total
  }

  private static func summary(_ row: Row) -> ClipSummary {
    ClipSummary(
      id: row.int64(0),
      kind: ClipKind(rawValue: row.int(1)) ?? .text,
      title: row.string(2),
      appBundleID: row.optionalString(3),
      appName: row.optionalString(4),
      firstCopiedAt: row.date(5),
      lastCopiedAt: row.date(6),
      copyCount: row.int(7),
      pinnedAt: row.optionalDate(8),
      byteSize: row.int(9),
      imageWidth: row.optionalInt(10),
      imageHeight: row.optionalInt(11),
      hasRichText: row.int(12) != 0,
      fileCount: row.int(13),
      isSensitive: row.int(14) != 0,
      expiresAt: row.optionalDate(15)
    )
  }
}

extension Array {
  func chunked(into size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
  }
}

private struct RepresentationKey: Hashable {
  var itemIndex: Int
  var type: String
}

private struct StoredRepresentation {
  var itemIndex: Int
  var type: String
  var data: Data?
  var blob: String?
  var size: Int
}

extension SQLiteError {
  /// The file is not a database or is damaged. Only then may the store move it aside.
  var isDamagedFile: Bool {
    let primary = code & 0xFF
    return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
  }
}
