import Foundation
import Testing
@testable import MaccyCore

@Suite struct SearchQueryTests {
  @Test func plainTerms() {
    let query = SearchQuery.parse("  foo   bar ")
    #expect(query.terms == ["foo", "bar"])
    #expect(query.kind == nil)
    #expect(query.hasTextCondition)
  }

  @Test func filtersAndPhrases() {
    let query = SearchQuery.parse(#"type:image app:Slack is:pinned "hello world" x"#)
    #expect(query.kind == .image)
    #expect(query.app == "Slack")
    #expect(query.pinnedOnly)
    #expect(query.terms == ["hello world", "x"])
  }

  @Test func unknownTypeIsATerm() {
    #expect(SearchQuery.parse("type:banana").terms == ["type:banana"])
  }

  @Test func explicitKindIsKeptWhenNoToken() {
    #expect(SearchQuery.parse("foo", kind: .link).kind == .link)
  }

  @Test func regex() {
    #expect(SearchQuery.parse("/^a.*z$/").regex == "^a.*z$")
    #expect(SearchQuery.parse("/").regex == nil)
  }
}

@Suite struct FuzzyMatcherTests {
  @Test func matchesSubsequence() throws {
    let match = try #require(FuzzyMatcher.match("gtcm", in: "git commit -m"))
    #expect(match.positions == [0, 2, 4, 6])
    #expect(FuzzyMatcher.ranges(from: [0, 1, 2, 5]) == [0..<3, 5..<6])
  }

  @Test func rejectsMissingLetters() {
    #expect(FuzzyMatcher.match("xyz", in: "git commit") == nil)
  }

  @Test func prefersWordStarts() throws {
    let wordStarts = try #require(FuzzyMatcher.match("pr", in: "pull request"))
    let scattered = try #require(FuzzyMatcher.match("pr", in: "pear"))
    #expect(wordStarts.score > scattered.score)
  }
}

@Suite struct RankerTests {
  @Test func titlePrefixBeatsMiddle() {
    let now = Date.now
    let candidates = [
      Ranker.Candidate(summary: ClipSummary(id: 1, kind: .text, title: "the deploy script", lastCopiedAt: now), bodyPrefix: "", ocrPrefix: ""),
      Ranker.Candidate(summary: ClipSummary(id: 2, kind: .text, title: "deploy now", lastCopiedAt: now), bodyPrefix: "", ocrPrefix: ""),
    ]
    let hits = Ranker.rank(candidates, terms: ["deploy"], now: now)
    #expect(hits.map(\.id) == [2, 1])
    #expect(hits[1].titleMatches == [4..<10])
  }

  @Test func recencyBreaksTies() {
    let now = Date.now
    let candidates = [
      Ranker.Candidate(summary: ClipSummary(id: 1, kind: .text, title: "alpha", lastCopiedAt: now.addingTimeInterval(-30 * 86_400)), bodyPrefix: "", ocrPrefix: ""),
      Ranker.Candidate(summary: ClipSummary(id: 2, kind: .text, title: "alpha", lastCopiedAt: now), bodyPrefix: "", ocrPrefix: ""),
    ]
    #expect(Ranker.rank(candidates, terms: ["alpha"], now: now).map(\.id) == [2, 1])
  }
}
