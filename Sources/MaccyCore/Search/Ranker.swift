import Foundation

/// Scores search candidates. A better position of a match gives a higher score,
/// and recent or often-copied items get a small boost.
enum Ranker {
  struct Candidate {
    var summary: ClipSummary
    var bodyPrefix: String
    var ocrPrefix: String
  }

  static let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

  static func rank(_ candidates: [Candidate], terms: [String], now: Date) -> [SearchHit] {
    candidates.map { candidate in
      var score = 0.0
      var titleMatches: [Range<Int>] = []
      let title = candidate.summary.title

      for term in terms {
        if let range = title.range(of: term, options: compareOptions) {
          titleMatches.append(characterOffsets(of: range, in: title))
          if range.lowerBound == title.startIndex {
            score += 100
          } else if isWordStart(range.lowerBound, in: title) {
            score += 75
          } else {
            score += 50
          }
        } else if let range = candidate.bodyPrefix.range(of: term, options: compareOptions) {
          score += isWordStart(range.lowerBound, in: candidate.bodyPrefix) ? 35 : 25
        } else if candidate.ocrPrefix.range(of: term, options: compareOptions) != nil {
          score += 20
        } else if candidate.summary.appName?.range(of: term, options: compareOptions) != nil {
          score += 15
        } else {
          // Matched by the full-text index beyond the prefix that the ranker reads.
          score += 10
        }
      }

      score += recencyBoost(lastCopiedAt: candidate.summary.lastCopiedAt, now: now)
      score += min(10, 3 * log2(Double(max(1, candidate.summary.copyCount))))
      if candidate.summary.isPinned {
        score += 10
      }
      return SearchHit(summary: candidate.summary, titleMatches: merge(titleMatches), score: score)
    }
    .sorted { lhs, rhs in
      lhs.score != rhs.score ? lhs.score > rhs.score : lhs.summary.lastCopiedAt > rhs.summary.lastCopiedAt
    }
  }

  /// Up to 30 points. The boost halves every three days.
  static func recencyBoost(lastCopiedAt: Date, now: Date) -> Double {
    let ageHours = max(0, now.timeIntervalSince(lastCopiedAt) / 3_600)
    return 30 * pow(0.5, ageHours / 72)
  }

  static func isWordStart(_ index: String.Index, in string: String) -> Bool {
    guard index > string.startIndex else {
      return true
    }
    let previous = string[string.index(before: index)]
    let current = string[index]
    if previous.isWhitespace || previous.isPunctuation || previous.isSymbol {
      return true
    }
    return previous.isLowercase && current.isUppercase
  }

  static func characterOffsets(of range: Range<String.Index>, in string: String) -> Range<Int> {
    let lower = string.distance(from: string.startIndex, to: range.lowerBound)
    let upper = lower + string.distance(from: range.lowerBound, to: range.upperBound)
    return lower..<upper
  }

  static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
    let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
    var output: [Range<Int>] = []
    for range in sorted {
      if let last = output.last, range.lowerBound <= last.upperBound {
        output[output.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        output.append(range)
      }
    }
    return output
  }
}

/// A subsequence matcher in the style of fzf. It is the fallback when no item
/// contains the query as a substring.
public enum FuzzyMatcher {
  public static func match(_ pattern: String, in candidate: String) -> (score: Double, positions: [Int])? {
    let needle = Array(pattern.lowercased().filter { !$0.isWhitespace })
    guard !needle.isEmpty else {
      return nil
    }
    let haystack = Array(candidate)
    var positions: [Int] = []
    positions.reserveCapacity(needle.count)
    var score = 0.0
    var needleIndex = 0
    var previousMatch = -2

    for (index, character) in haystack.enumerated() where needleIndex < needle.count {
      guard character.lowercased().first == needle[needleIndex] else {
        continue
      }
      var bonus = 1.0
      if index == previousMatch + 1 {
        bonus += 5
      }
      if index == 0 {
        bonus += 8
      } else {
        let previous = haystack[index - 1]
        if previous.isWhitespace || previous.isPunctuation || previous.isSymbol {
          bonus += 8
        } else if previous.isLowercase && character.isUppercase {
          bonus += 6
        }
      }
      score += bonus
      positions.append(index)
      previousMatch = index
      needleIndex += 1
    }

    guard needleIndex == needle.count, let first = positions.first, let last = positions.last else {
      return nil
    }
    let gaps = Double(last - first + 1 - needle.count)
    score -= gaps * 0.5
    // Reject weak matches: letters spread far apart in a long string.
    guard score >= Double(needle.count) * 2 else {
      return nil
    }
    return (score, positions)
  }

  /// Converts matched positions to contiguous ranges for highlight.
  public static func ranges(from positions: [Int]) -> [Range<Int>] {
    var output: [Range<Int>] = []
    for position in positions {
      if let last = output.last, last.upperBound == position {
        output[output.count - 1] = last.lowerBound..<(position + 1)
      } else {
        output.append(position..<(position + 1))
      }
    }
    return output
  }
}
