import Foundation

/// Finds credentials in copied text, so they do not stay in the history.
public enum SecretDetector {
  public struct Rule: Sendable {
    public let name: String
    let regex: NSRegularExpression
  }

  /// The base64url characters of most tokens.
  private static let base64URL = "A-Za-z0-9_-"

  /// A token whose characters include `-`: `prefix`, then `body`, made of the
  /// characters in the class `characters`. `\b` does not work for these tokens:
  /// - At the end, `\b` fails after a final `-`, so a key that ends with `-` (about
  ///   1 in 64 for base64url) did not match.
  /// - At the start, `\b` lets a match start after each `-` inside a run such as
  ///   `xoxb-xoxb-…`, and each start scans to the end of the run: quadratic time,
  ///   12 s for 50 KB.
  /// So the token cannot start or end next to one of its own characters. Then each
  /// run is scanned once, and the scan stays linear.
  private static func token(_ prefix: String, _ body: String, characters: String) -> String {
    "(?<![\(characters)])\(prefix)\(body)(?![\(characters)])"
  }

  // Patterns are anchored on well-known token prefixes to keep false positives low.
  // Order matters: the first match names the secret, so a specific rule comes first.
  public static let rules: [Rule] = [
    ("AWS access key", #"\b(AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b"#),
    ("GitHub token", #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b"#),
    ("GitHub token", #"\bgithub_pat_[A-Za-z0-9_]{60,}\b"#),
    ("GitLab token", token("glpat-", "[\(base64URL)]{20,}", characters: base64URL)),
    // Bot, user, app, refresh and configuration tokens (xoxe.xoxp-… matches at xoxp-).
    ("Slack token", token("xox[abeoprs]-", "[A-Za-z0-9-]{10,}", characters: "A-Za-z0-9-")),
    ("Slack token", token(#"xapp-\d-"#, "[A-Za-z0-9-]{10,}", characters: "A-Za-z0-9-")),
    ("Slack webhook", #"https://hooks\.slack\.com/services/[A-Za-z0-9/_-]{20,}"#),
    ("Stripe key", #"\b[rs]k_(live|test)_[A-Za-z0-9]{20,}\b"#),
    // Exactly 35 characters, so each start scans at most 35: `\b` at the start is fine.
    ("Google API key", #"\bAIza[\#(base64URL)]{35}(?![\#(base64URL)])"#),
    ("Anthropic key", token("sk-ant-", "[\(base64URL)]{32,}", characters: base64URL)),
    // Project, service account and admin keys, then the two older formats. A plain
    // `sk-` with dashes is often a branch name (sk-1234-fix-login), so it does not match.
    ("OpenAI key", token("sk-(proj|svcacct|admin)-", "[\(base64URL)]{40,}", characters: base64URL)),
    ("OpenAI key", #"\bsk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}\b"#),
    ("OpenAI key", #"\bsk-[A-Za-z0-9]{48}\b"#),
    ("npm token", #"\bnpm_[A-Za-z0-9]{36}\b"#),
    ("JSON Web Token", token(
      "eyJ", #"[\#(base64URL)]{8,}\.eyJ[\#(base64URL)]{8,}\.[\#(base64URL)]{16,}"#, characters: base64URL
    )),
    // RSA, EC, OPENSSH, ENCRYPTED and PGP (… PRIVATE KEY BLOCK) keys.
    ("Private key", #"-----BEGIN ([A-Z0-9]+ ){0,3}PRIVATE KEY( BLOCK)?-----"#),
    ("Azure connection string", #"AccountKey=[A-Za-z0-9+/=]{40,}"#),
  ].compactMap { name, pattern in
    (try? NSRegularExpression(pattern: pattern)).map { Rule(name: name, regex: $0) }
  }

  /// Returns the name of the first rule that matches, or `nil`.
  /// Each rule is anchored on a prefix and scans each run of token characters once,
  /// so the scan is linear: about 1 s for 20 MB (the largest text that Maccy saves),
  /// also for crafted text. It runs off the main thread.
  public static func detect(in text: String) -> String? {
    guard !text.isEmpty else {
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

  /// The time for all patterns together, for one copy: 0.25 s, plus 0.15 s for each
  /// million characters. The check runs on the capture queue, so a slow pattern must
  /// not delay the copies after it. A simple pattern scans about 1 MB in 30 ms, so a
  /// linear scan of the largest text (20 MB) has five times the time it needs.
  public static func timeLimit(forLength length: Int) -> Duration {
    .milliseconds(250) + .milliseconds(150) * (Double(length) / 1_000_000)
  }

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
  public func evaluate(_ text: String, timeLimit: Duration? = nil) -> Verdict {
    let range = NSRange(text.startIndex..., in: text)
    let deadline = ContinuousClock.now + (timeLimit ?? Self.timeLimit(forLength: range.length))
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
