import Foundation

/// Finds credentials in copied text, so they do not stay in the history.
public enum SecretDetector {
  public struct Rule: Sendable {
    public let name: String
    let regex: NSRegularExpression
  }

  // Patterns are anchored on well-known token prefixes to keep false positives low.
  public static let rules: [Rule] = [
    ("AWS access key", #"\b(AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b"#),
    ("GitHub token", #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b"#),
    ("GitHub token", #"\bgithub_pat_[A-Za-z0-9_]{60,}\b"#),
    ("GitLab token", #"\bglpat-[A-Za-z0-9_\-]{20,}\b"#),
    ("Slack token", #"\bxox[abposr]-[A-Za-z0-9-]{10,}\b"#),
    ("Slack webhook", #"https://hooks\.slack\.com/services/[A-Za-z0-9/_-]{20,}"#),
    ("Stripe key", #"\b[rs]k_(live|test)_[A-Za-z0-9]{20,}\b"#),
    ("Google API key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
    ("OpenAI key", #"\bsk-(proj-)?[A-Za-z0-9_\-]{32,}\b"#),
    ("Anthropic key", #"\bsk-ant-[A-Za-z0-9_\-]{32,}\b"#),
    ("npm token", #"\bnpm_[A-Za-z0-9]{36}\b"#),
    ("JSON Web Token", #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{16,}\b"#),
    ("Private key", #"-----BEGIN ([A-Z]+ )?PRIVATE KEY-----"#),
    ("Azure connection string", #"AccountKey=[A-Za-z0-9+/=]{40,}"#),
  ].compactMap { name, pattern in
    (try? NSRegularExpression(pattern: pattern)).map { Rule(name: name, regex: $0) }
  }

  /// Returns the name of the first rule that matches, or `nil`.
  public static func detect(in text: String) -> String? {
    // Secrets are short. Skip the scan for very large texts.
    guard !text.isEmpty, text.utf16.count <= 100_000 else {
      return nil
    }
    let range = NSRange(text.startIndex..., in: text)
    return rules.first { $0.regex.firstMatch(in: text, range: range) != nil }?.name
  }
}

/// User regular expressions for the "ignore copies that match" rule.
/// The patterns compile once, when the setting changes.
public struct IgnorePatterns: Sendable {
  public enum Verdict: Sendable, Equatable {
    case match
    case noMatch
    /// A pattern did not finish in the time limit (for example `.*password` on a
    /// large copy, which takes quadratic time). The copy is not checked.
    case timedOut
  }

  /// The time for all patterns together, for one copy. The check runs on the
  /// capture queue, so a slow pattern must not delay the copies after it.
  public static let timeLimit: Duration = .milliseconds(250)

  private let regexes: [NSRegularExpression]
  public let invalidPatterns: [String]

  public init(_ patterns: [String]) {
    var regexes: [NSRegularExpression] = []
    var invalid: [String] = []
    for pattern in patterns where !pattern.isEmpty {
      if let regex = try? NSRegularExpression(pattern: pattern) {
        regexes.append(regex)
      } else {
        invalid.append(pattern)
      }
    }
    self.regexes = regexes
    self.invalidPatterns = invalid
  }

  public var isEmpty: Bool { regexes.isEmpty }

  /// An invalid pattern does not stop the check of the other patterns.
  public func evaluate(_ text: String, timeLimit: Duration = Self.timeLimit) -> Verdict {
    let range = NSRange(text.startIndex..., in: text)
    let deadline = ContinuousClock.now + timeLimit
    for regex in regexes {
      var found = false
      var timedOut = false
      // `.reportProgress` calls the block during a long match, so the deadline also
      // stops a pattern that backtracks.
      regex.enumerateMatches(in: text, options: [.reportProgress], range: range) { match, _, stop in
        if match != nil {
          found = true
          stop.pointee = true
        } else if ContinuousClock.now >= deadline {
          timedOut = true
          stop.pointee = true
        }
      }
      if found {
        return .match
      }
      if timedOut {
        return .timedOut
      }
    }
    return .noMatch
  }
}
