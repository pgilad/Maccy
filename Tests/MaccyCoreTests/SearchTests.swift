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

  @Test func quotedFilterValue() {
    let query = SearchQuery.parse(#"app:"Google Chrome" tab type:"image""#)
    #expect(query.app == "Google Chrome")
    #expect(query.kind == .image)
    #expect(query.terms == ["tab"])
    // Still typing: the value runs to the end.
    #expect(SearchQuery.parse(#"app:"Google Chr"#).app == "Google Chr")
  }

  @Test func regexWithFilters() {
    let query = SearchQuery.parse(#"type:text /order \d+/ app:"Google Chrome""#)
    #expect(query.regex == #"order \d+"#)
    #expect(query.kind == .text)
    #expect(query.app == "Google Chrome")
    #expect(query.terms.isEmpty)
    #expect(SearchQuery.parse("/a/b/ is:pinned").regex == "a/b")
  }

  @Test(arguments: ["/usr/bin", "cp /var/log/*.log /tmp/", "mv /tmp/(draft /docs/", #""a /b c/ d""#, "/a/ word"])
  func pathsAndWordsAreNotARegex(_ text: String) {
    #expect(SearchQuery.parse(text).regex == nil)
  }

  @Test func quotedValueOnlyAfterAKnownFilter() {
    #expect(SearchQuery.parse(#"json:"user_id""#).terms == ["json:", "user_id"])
    #expect(SearchQuery.parse(#"APP:"Google Chrome""#).app == "Google Chrome")
  }

  @Test func unbalancedQuoteIsAPhrase() {
    #expect(SearchQuery.parse(#"say "hello wor"#).terms == ["say", "hello wor"])
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

  @Test func findsTheBestStartNotTheFirst() throws {
    let match = try #require(FuzzyMatcher.match("gcm", in: "debug log: git commit"))
    #expect(match.positions == [11, 15, 17])
  }

  @Test func ignoresDiacritics() throws {
    #expect(FuzzyMatcher.match("crmbr", in: "Crème brûlée") != nil)
    #expect(FuzzyMatcher.match("ÉCLR", in: "ecler") != nil)
  }

  @Test func prefersWordStarts() throws {
    let wordStarts = try #require(FuzzyMatcher.match("pr", in: "pull request"))
    let scattered = try #require(FuzzyMatcher.match("pr", in: "pear"))
    #expect(wordStarts.score > scattered.score)
  }
}

@Suite struct SearchFoldingTests {
  @Test(arguments: [
    ("Crème brûlée", "creme"), ("CRÈME", "crè"), ("e\u{301}cole", "ecole"), ("Привет МИР", "мир"),
    ("ёлка", "елка"), ("שָׁלוֹם", "שלום"), ("go build", "GO"), ("İstanbul", "istanbul"), ("aab", "ab"),
  ])
  func matchesLikeFoundation(_ text: String, _ needle: String) {
    #expect(FoldedNeedle(needle).isFound(in: text))
    #expect(text.range(of: needle, options: SearchFolding.options) != nil)
  }

  @Test(arguments: [("hello", "xyz"), ("abc", "abd"), ("ab", "abc"), ("עולם", "של")])
  func rejectsMissingText(_ text: String, _ needle: String) {
    #expect(!FoldedNeedle(needle).isFound(in: text))
  }
}

@Suite struct RankerTests {
  @Test func titlePrefixBeatsMiddle() {
    let now = Date.now
    let candidates = [
      candidate(id: 1, title: "the deploy script", at: now),
      candidate(id: 2, title: "deploy now", at: now),
    ]
    let hits = Ranker.rank(candidates, terms: ["deploy"], now: now)
    #expect(hits.map(\.id) == [2, 1])
    #expect(hits[1].titleMatches == [4..<10])
  }

  @Test func recencyBreaksTies() {
    let now = Date.now
    let candidates = [
      candidate(id: 1, title: "alpha", at: now.addingTimeInterval(-30 * 86_400)),
      candidate(id: 2, title: "alpha", at: now),
    ]
    #expect(Ranker.rank(candidates, terms: ["alpha"], now: now).map(\.id) == [2, 1])
  }

  private func candidate(id: Int64, title: String, at date: Date) -> Ranker.Candidate {
    Ranker.Candidate(summary: ClipSummary(id: id, kind: .text, title: title, lastCopiedAt: date), bodyPrefix: "", ocrPrefix: "")
  }
}
