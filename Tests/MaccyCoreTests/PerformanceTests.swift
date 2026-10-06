import Foundation
import Testing
@testable import MaccyCore

/// Run with `MACCY_PERF=1 make test` to measure search on a large history.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACCY_PERF"] == "1"))
struct PerformanceTests {
  static let words = """
    alpha beta gamma delta kubectl docker deploy commit branch merge invoice report meeting \
    password token config server client request response error warning function variable \
    swift rust python golang javascript typescript react vapor postgres sqlite cache index
    """.split(separator: " ").map(String.init)

  @Test func searchOnHundredThousandItems() async throws {
    let store = try makeStore()
    let count = 100_000
    let now = Date.now
    var generator = SystemRandomNumberGenerator()
    var clock = ContinuousClock.now

    for batchStart in stride(from: 0, to: count, by: 5_000) {
      let batch = (batchStart..<min(count, batchStart + 5_000)).map { index -> AnalyzedClip in
        let length = Int.random(in: 5...60, using: &generator)
        let text = (0..<length).map { _ in Self.words.randomElement(using: &generator)! }.joined(separator: " ")
        return analyzed("\(text) #\(index)", app: index.isMultiple(of: 3) ? "Slack" : "Terminal",
                        at: now.addingTimeInterval(Double(index - count)))
      }
      try await store.upsert(batch: batch)
    }
    print("insert \(count): \(ContinuousClock.now - clock)")

    for (label, query) in [
      ("recent 300", ""), ("3-char term", "kub"), ("two terms", "docker deploy"),
      ("rare term", "#99999"), ("short term", "go"), ("rare short term", "zq"), ("Cyrillic short term", "жё"),
      ("app filter", "app:slack invoice"),
      ("fuzzy fallback", "zqxv"), ("regex", "/token \\w+ config/"),
    ] {
      clock = .now
      let hits: Int
      if query.isEmpty {
        hits = try await store.recent(limit: 300).count
      } else {
        hits = try await store.search(SearchQuery.parse(query), limit: 300).hits.count
      }
      print("\(label) (\(query)): \(hits) hits in \(ContinuousClock.now - clock)")
    }
    let stats = try await store.stats()
    print("items: \(stats.itemCount), disk: \(stats.diskBytes / 1_048_576) MB")
  }
}
