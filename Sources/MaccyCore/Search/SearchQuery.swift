import Foundation

/// A parsed search string.
///
/// Syntax:
/// - Words match anywhere (all words must match), case- and diacritic-insensitive.
/// - `"two words"` matches a phrase.
/// - `type:image` (or `text`, `link`, `file`, `color`) filters by kind.
/// - `app:slack` filters by source application.
/// - `is:pinned` shows pinned items only.
/// - `/regex/` matches a regular expression (case-insensitive).
public struct SearchQuery: Sendable, Equatable {
  public var terms: [String] = []
  public var kind: ClipKind?
  public var app: String?
  public var pinnedOnly = false
  public var regex: String?

  public init(terms: [String] = [], kind: ClipKind? = nil, app: String? = nil, pinnedOnly: Bool = false, regex: String? = nil) {
    self.terms = terms
    self.kind = kind
    self.app = app
    self.pinnedOnly = pinnedOnly
    self.regex = regex
  }

  /// `true` when the query has no text condition (filters only).
  public var hasTextCondition: Bool { !terms.isEmpty || regex != nil }

  public var isEmpty: Bool { !hasTextCondition && app == nil && !pinnedOnly && kind == nil }

  public static func parse(_ text: String, kind: ClipKind? = nil) -> SearchQuery {
    var query = SearchQuery(kind: kind)
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    if trimmed.count > 2, trimmed.hasPrefix("/"), trimmed.hasSuffix("/") {
      query.regex = String(trimmed.dropFirst().dropLast())
      return query
    }

    for token in tokenize(trimmed) {
      if token.isPhrase {
        query.terms.append(token.text)
        continue
      }
      let lowercased = token.text.lowercased()
      if let value = value(of: lowercased, prefixes: ["type:", "kind:"]), let parsedKind = ClipKind(searchToken: value) {
        query.kind = parsedKind
      } else if let value = value(of: token.text, prefixes: ["app:"]), !value.isEmpty {
        query.app = value
      } else if lowercased == "is:pinned" {
        query.pinnedOnly = true
      } else {
        query.terms.append(token.text)
      }
    }
    return query
  }

  private static func value(of token: String, prefixes: [String]) -> String? {
    for prefix in prefixes where token.lowercased().hasPrefix(prefix) {
      return String(token.dropFirst(prefix.count))
    }
    return nil
  }

  private struct Token {
    var text: String
    var isPhrase: Bool
  }

  private static func tokenize(_ text: String) -> [Token] {
    var tokens: [Token] = []
    var current = ""
    var inQuotes = false
    for character in text {
      if character == "\"" {
        if inQuotes {
          if !current.isEmpty {
            tokens.append(Token(text: current, isPhrase: true))
          }
          current = ""
        } else if !current.isEmpty {
          tokens.append(Token(text: current, isPhrase: false))
          current = ""
        }
        inQuotes.toggle()
      } else if character.isWhitespace && !inQuotes {
        if !current.isEmpty {
          tokens.append(Token(text: current, isPhrase: false))
        }
        current = ""
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty {
      tokens.append(Token(text: current, isPhrase: inQuotes))
    }
    return tokens
  }
}
