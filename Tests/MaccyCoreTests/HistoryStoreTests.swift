import Foundation
import Testing
@testable import MaccyCore

@Suite struct HistoryStoreTests {
  @Test func duplicateMovesToTopAndCounts() async throws {
    let store = try makeStore()
    let start = Date(timeIntervalSince1970: 1_000_000)
    let first = try await insert(store, "alpha", at: start)
    try await insert(store, "beta", at: start.addingTimeInterval(1))
    let again = try await insert(store, "alpha", app: "Terminal", at: start.addingTimeInterval(2))

    #expect(first.isNew)
    #expect(!again.isNew)
    #expect(again.id == first.id)

    let recent = try await store.recent(limit: 10)
    #expect(recent.map(\.title) == ["alpha", "beta"])
    #expect(recent[0].copyCount == 2)
    #expect(recent[0].firstCopiedAt == start)
    #expect(recent[0].appName == "Terminal")
  }

  @Test func pinnedItemsComeFirstInPinOrder() async throws {
    let store = try makeStore()
    let a = try await insert(store, "a1")
    let b = try await insert(store, "b1")
    try await insert(store, "c1")
    try await store.setPinned(id: b.id, true, at: .now)
    try await store.setPinned(id: a.id, true, at: .now.addingTimeInterval(1))

    let recent = try await store.recent(limit: 10)
    #expect(recent.map(\.title) == ["b1", "a1", "c1"])
    #expect(recent[0].isPinned)

    try await store.setPinned(id: b.id, false)
    #expect(try await store.recent(limit: 10).map(\.title) == ["a1", "c1", "b1"])
  }

  @Test func kindFilter() async throws {
    let store = try makeStore()
    try await insert(store, "plain words")
    try await insert(store, "https://example.com")
    #expect(try await store.recent(kind: .link, limit: 10).map(\.title) == ["https://example.com"])
  }

  @Test func searchFindsSubstringsAnywhereInBody() async throws {
    let store = try makeStore()
    let long = String(repeating: "filler ", count: 2_000) + "needleInHaystack"
    try await insert(store, long)
    try await insert(store, "Crème brûlée recipe")
    try await insert(store, "unrelated")

    let needle = try await store.search(SearchQuery.parse("inhay"), limit: 10).hits
    #expect(needle.count == 1)

    // Case- and diacritic-insensitive.
    let dessert = try await store.search(SearchQuery.parse("CREME brulee"), limit: 10).hits
    #expect(dessert.map(\.summary.title) == ["Crème brûlée recipe"])
  }

  @Test func shortTermsUseLike() async throws {
    let store = try makeStore()
    try await insert(store, "go build")
    try await insert(store, "swift build")
    let hits = try await store.search(SearchQuery.parse("go"), limit: 10).hits
    #expect(hits.map(\.summary.title) == ["go build"])
    #expect(hits[0].titleMatches == [0..<2])
  }

  @Test func searchRanksTitleMatchesFirst() async throws {
    let store = try makeStore()
    try await insert(store, "notes about kubectl apply in the body", at: .now)
    try await insert(store, "kubectl get pods", at: .now.addingTimeInterval(-3_600))
    let hits = try await store.search(SearchQuery.parse("kubectl"), limit: 10).hits
    #expect(hits.first?.summary.title == "kubectl get pods")
  }

  @Test func appAndPinnedFilters() async throws {
    let store = try makeStore()
    try await insert(store, "from slack", app: "Slack")
    let notes = try await insert(store, "from notes", app: "Notes")
    try await store.setPinned(id: notes.id, true)

    #expect(try await store.search(SearchQuery.parse("app:sla"), limit: 10).hits.map(\.summary.title) == ["from slack"])
    #expect(try await store.search(SearchQuery.parse("is:pinned"), limit: 10).hits.map(\.summary.title) == ["from notes"])
    let combined = try await store.search(SearchQuery.parse("from app:notes"), limit: 10).hits
    #expect(combined.map(\.summary.title) == ["from notes"])
  }

  @Test func regexSearch() async throws {
    let store = try makeStore()
    try await insert(store, "order 12345")
    try await insert(store, "order abc")
    let hits = try await store.search(SearchQuery.parse("/order \\d+/"), limit: 10).hits
    #expect(hits.map(\.summary.title) == ["order 12345"])
    #expect(hits[0].titleMatches == [0..<11])
    #expect(try await store.search(SearchQuery.parse("/([/"), limit: 10) == .invalidRegex("(["))
  }

  @Test func fuzzyFallback() async throws {
    let store = try makeStore()
    try await insert(store, "git commit --amend")
    try await insert(store, "docker compose up")
    let hits = try await store.search(SearchQuery.parse("gcam"), limit: 10).hits
    #expect(hits.map(\.summary.title) == ["git commit --amend"])
  }

  @Test func ocrTextIsSearchable() async throws {
    let store = try makeStore()
    let image = try #require(ClipAnalyzer.analyze(CapturedClip(representations: [
      Representation(type: PasteboardTypes.png, data: makeImage(width: 10, height: 10))
    ])))
    let result = try await store.upsert(image, thumbnail: Data([1, 2, 3]), expiresAt: nil)
    try await store.setOCRText(id: result.id, text: "Invoice total 42")
    #expect(try await store.search(SearchQuery.parse("invoice"), limit: 10).hits.map(\.id) == [result.id])
    #expect(try await store.thumbnail(id: result.id) == Data([1, 2, 3]))
  }

  @Test func largeRepresentationsUseBlobFilesAndAreDeleted() async throws {
    let directory = makeTemporaryDirectory()
    let store = try HistoryStore(directory: directory)
    let image = makeNoiseImage(width: 200, height: 200)
    let clip = try #require(ClipAnalyzer.analyze(CapturedClip(representations: [
      Representation(type: PasteboardTypes.png, data: image)
    ])))
    #expect(image.count > HistoryStore.inlineLimit)

    let result = try await store.upsert(clip, thumbnail: nil, expiresAt: nil)
    let blobFile = BlobStore.key(for: image)
    let blobURL = directory.appending(path: "blobs/\(blobFile.prefix(2))/\(blobFile)")
    #expect(FileManager.default.fileExists(atPath: blobURL.path))
    #expect(try await store.imageData(id: result.id) == image)
    #expect(try await store.representations(id: result.id).map(\.data) == [image])

    try await store.delete(ids: [result.id])
    #expect(!FileManager.default.fileExists(atPath: blobURL.path))
  }

  @Test func detailAndRepresentationsRoundTrip() async throws {
    let store = try makeStore()
    let clip = try #require(ClipAnalyzer.analyze(CapturedClip(representations: [
      Representation(type: PasteboardTypes.string, data: Data("rich".utf8)),
      Representation(type: PasteboardTypes.html, data: Data("<b>rich</b>".utf8)),
    ])))
    let result = try await store.upsert(clip, thumbnail: nil, expiresAt: nil)
    let detail = try #require(try await store.detail(id: result.id))
    #expect(detail.text == "rich")
    #expect(detail.summary.hasRichText)
    #expect(detail.representationTypes == [PasteboardTypes.string, PasteboardTypes.html])
    #expect(try await store.representations(id: result.id).count == 2)
  }

  @Test func pruneByAgeCountAndSize() async throws {
    let store = try makeStore()
    let now = Date.now
    for day in 0..<10 {
      try await insert(store, "item \(day)", at: now.addingTimeInterval(Double(-day) * 86_400))
    }
    let old = try await store.search(SearchQuery.parse("item 9"), limit: 1).hits[0]
    try await store.setPinned(id: old.id, true)

    #expect(try await store.prune(policy: RetentionPolicy(maxAge: 5.5 * 86_400), now: now) == 3)
    #expect(try await store.stats().itemCount == 7)

    #expect(try await store.prune(policy: RetentionPolicy(maxItems: 3), now: now) == 3)
    let titles = try await store.recent(limit: 10).map(\.title)
    #expect(titles == ["item 9", "item 0", "item 1", "item 2"])

    // Each item is 6 bytes. Keep two unpinned items.
    #expect(try await store.prune(policy: RetentionPolicy(maxTotalBytes: 12), now: now) == 1)
    #expect(try await store.recent(limit: 10).map(\.title) == ["item 9", "item 0", "item 1"])
  }

  @Test func expiredSecretsArePrunedUnlessPinned() async throws {
    let store = try makeStore()
    let now = Date.now
    let secret = try #require(ClipAnalyzer.analyze(textClip(FakeSecrets.awsKey)))
    let kept = try #require(ClipAnalyzer.analyze(textClip(FakeSecrets.otherAWSKey)))
    try await store.upsert(secret, thumbnail: nil, expiresAt: now.addingTimeInterval(60))
    let pinned = try await store.upsert(kept, thumbnail: nil, expiresAt: now.addingTimeInterval(60))
    try await store.setPinned(id: pinned.id, true)

    #expect(try await store.nextExpiry() != nil)
    #expect(try await store.prune(policy: RetentionPolicy(), now: now) == 0)
    #expect(try await store.prune(policy: RetentionPolicy(), now: now.addingTimeInterval(61)) == 1)
    let remaining = try await store.recent(limit: 10)
    #expect(remaining.map(\.id) == [pinned.id])
    #expect(remaining[0].isSensitive)
    #expect(remaining[0].expiresAt == nil)
  }

  @Test func deleteAllKeepsPinned() async throws {
    let store = try makeStore()
    let pinned = try await insert(store, "keep")
    try await insert(store, "drop")
    try await store.setPinned(id: pinned.id, true)
    #expect(try await store.deleteAll(keepPinned: true) == 1)
    #expect(try await store.recent(limit: 10).map(\.title) == ["keep"])
    #expect(try await store.deleteAll(keepPinned: false) == 1)
    #expect(try await store.search(SearchQuery.parse("keep"), limit: 10).hits.isEmpty)
  }

  @Test func touchMovesToTop() async throws {
    let store = try makeStore()
    let first = try await insert(store, "first", at: .now.addingTimeInterval(-10))
    try await insert(store, "second", at: .now.addingTimeInterval(-5))
    try await store.touch(id: first.id)
    let recent = try await store.recent(limit: 10)
    #expect(recent.map(\.title) == ["first", "second"])
    #expect(recent[0].copyCount == 2)
  }

  @Test func corruptDatabaseIsMovedAside() async throws {
    let directory = makeTemporaryDirectory()
    let path = directory.appending(path: HistoryStore.databaseFileName)
    try Data("this is not a database file, just junk bytes".utf8).write(to: path)
    let store = try HistoryStore(directory: directory)
    try await insert(store, "works")
    #expect(try await store.stats().itemCount == 1)
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(files.contains { $0.hasPrefix("history.sqlite.corrupt-") })
  }

  @Test func garbageCollectionRemovesUnreferencedBlobs() async throws {
    let directory = makeTemporaryDirectory()
    let store = try HistoryStore(directory: directory)
    let blobs = try BlobStore(directory: directory.appending(path: "blobs"))
    let key = try blobs.write(Data(repeating: 7, count: 10))
    #expect(try await store.collectGarbage() == 1)
    #expect(blobs.read(key) == nil)
  }

  @Test func storeIsExcludedFromBackup() throws {
    let directory = makeTemporaryDirectory()
    _ = try HistoryStore(directory: directory)
    let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
  }

  @Test func sizeLimitNeverDeletesTheNewestItem() async throws {
    let store = try makeStore()
    let now = Date.now
    try await insert(store, "old one", at: now.addingTimeInterval(-60))
    try await insert(store, String(repeating: "x", count: 500), at: now)
    #expect(try await store.prune(policy: RetentionPolicy(maxTotalBytes: 100), now: now) == 1)
    #expect(try await store.recent(limit: 10).map(\.title.count) == [300])
  }

  @Test func idsAreNotReused() async throws {
    let store = try makeStore()
    try await insert(store, "first")
    let second = try await insert(store, "second")
    try await store.delete(ids: [second.id])
    let third = try await insert(store, "third")
    #expect(third.id > second.id)
  }

  @Test func duplicateKeepsFormattingFromEarlierCopy() async throws {
    let store = try makeStore()
    let rich = try #require(ClipAnalyzer.analyze(CapturedClip(representations: [
      Representation(type: PasteboardTypes.string, data: Data("same text".utf8)),
      Representation(type: PasteboardTypes.html, data: Data("<b>same text</b>".utf8)),
    ])))
    let first = try await store.upsert(rich, thumbnail: nil, expiresAt: nil)
    let plain = try await insert(store, "same text")
    #expect(plain.id == first.id)
    let types = try await store.representations(id: first.id).map(\.type)
    #expect(types == [PasteboardTypes.string, PasteboardTypes.html])
    #expect(try await store.summary(id: first.id)?.hasRichText == true)
    #expect(try await store.summary(id: first.id)?.byteSize == 9 + 16)
  }

  @Test func textWithEmbeddedNulIsStoredInFull() async throws {
    let store = try makeStore()
    let result = try await insert(store, "before\u{0}after")
    #expect(try await store.detail(id: result.id)?.text == "before\u{0}after")
  }

  @Test func latestUnpinnedSkipsPins() async throws {
    let store = try makeStore()
    try await insert(store, "plain", at: .now.addingTimeInterval(-10))
    let pinned = try await insert(store, "pinned")
    try await store.setPinned(id: pinned.id, true)
    #expect(try await store.latestUnpinned()?.title == "plain")
  }

  @Test func cancelledSearchStops() async throws {
    let store = try makeStore()
    let filler = String(repeating: "abcdefghij ", count: 9_000)
    try await store.upsert(batch: (0..<300).map { analyzed("\($0) \(filler)") })
    let start = ContinuousClock.now
    let task = Task {
      try await store.search(SearchQuery.parse("/(a|b|c)+zzz$/"), limit: 10)
    }
    // Cancel while the query runs, not before it starts.
    try await Task.sleep(for: .milliseconds(150))
    task.cancel()
    await #expect(throws: (any Error).self) {
      try await task.value
    }
    // The full scan takes several seconds. A cancelled one stops early.
    #expect(ContinuousClock.now - start < .seconds(1))
  }
}
