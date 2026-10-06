import Foundation

/// A parsed search string.
///
/// Syntax:
/// - Words match anywhere (all words must match), case- and diacritic-insensitive.
/// - `"two words"` matches a phrase.
/// - `type:image` (or `text`, `link`, `file`, `color`) filters by kind.
/// - `app:slack` filters by source application. `app:"Google Chrome"` quotes a value.
/// - `is:pinned` shows pinned items only.
/// - `/regex/` matches a regular expression (case-insensitive). Filters and words
///   can come before or after it: `type:text /order \d+/`.
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
    var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let regex = extractRegex(rest) {
      query.regex = regex.pattern
      rest = regex.remainder
    }

    for token in tokenize(rest) {
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

  /// A regular expression starts with `/` at the start of a word and ends at the
  /// last `/` that ends a word. So the pattern can contain spaces and `/`, and a
  /// path such as `/usr/bin` stays a word.
  private static func extractRegex(_ text: String) -> (pattern: String, remainder: String)? {
    let characters = Array(text)
    guard let open = characters.indices.first(where: { index in
      characters[index] == "/" && (index == 0 || characters[index - 1].isWhitespace)
    }), let close = characters.indices.last(where: { index in
      index > open + 1 && characters[index] == "/" && (index == characters.count - 1 || characters[index + 1].isWhitespace)
    }) else {
      return nil
    }
    return (
      String(characters[(open + 1)..<close]),
      String(characters[..<open]) + " " + String(characters[(close + 1)...])
    )
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
    // `app:"Google Chrome"`: the quotes belong to the value of a filter.
    var quotedValue = false
    for character in text {
      if character == "\"" {
        if inQuotes {
          if !current.isEmpty {
            tokens.append(Token(text: current, isPhrase: !quotedValue))
          }
          current = ""
          quotedValue = false
        } else if current.hasSuffix(":") {
          quotedValue = true
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
      tokens.append(Token(text: current, isPhrase: inQuotes && !quotedValue))
    }
    return tokens
  }
}
