import Foundation

public enum TextUtilities {
  /// U+FFFC (object replacement character) hangs CoreText line truncation on macOS 26
  /// when two or more appear next to non-Latin text. Filter per scalar, not per
  /// Character: U+FFFC with a combining mark is one grapheme cluster.
  public static func removingUnsafeScalars(_ string: String) -> String {
    guard string.unicodeScalars.contains("\u{FFFC}") else {
      return string
    }
    var scalars = String.UnicodeScalarView()
    for scalar in string.unicodeScalars where scalar != "\u{FFFC}" {
      scalars.append(scalar)
    }
    return String(scalars)
  }

  /// A one-line title: whitespace runs become one space, at most `maxLength` characters.
  public static func title(from text: String, maxLength: Int = 300) -> String {
    var output = ""
    output.reserveCapacity(min(text.utf8.count, maxLength))
    var pendingSpace = false
    var count = 0
    for character in removingUnsafeScalars(text.prefix(maxLength * 4).description) {
      if character.isWhitespace || character.isNewline {
        pendingSpace = !output.isEmpty
        continue
      }
      if pendingSpace {
        output.append(" ")
        count += 1
        pendingSpace = false
      }
      guard count < maxLength else {
        break
      }
      output.append(character)
      count += 1
    }
    return output
  }

  /// Plain text from HTML without WebKit. `NSAttributedString(html:)` needs the main
  /// thread and is slow, so the capture pipeline uses this simple converter.
  public static func plainText(fromHTML html: String) -> String {
    var text = html
    let replacements: [(String, String)] = [
      ("(?is)<(script|style|head)[^>]*>.*?</\\1>", ""),
      ("(?i)<br\\s*/?>", "\n"),
      ("(?i)</(p|div|li|tr|h[1-6]|blockquote|pre)>", "\n"),
      ("(?s)<[^>]+>", ""),
    ]
    for (pattern, template) in replacements {
      text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    return decodeEntities(text)
      .replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
      .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static let namedEntities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    "mdash": "—", "ndash": "–", "hellip": "…", "copy": "©", "reg": "®", "trade": "™",
  ]

  static func decodeEntities(_ string: String) -> String {
    guard string.contains("&") else {
      return string
    }
    var output = ""
    var index = string.startIndex
    while index < string.endIndex {
      let character = string[index]
      guard character == "&",
            let semicolon = string[index...].prefix(12).firstIndex(of: ";") else {
        output.append(character)
        index = string.index(after: index)
        continue
      }
      let entity = string[string.index(after: index)..<semicolon]
      if let decoded = decode(entity: entity) {
        output.append(decoded)
        index = string.index(after: semicolon)
      } else {
        output.append(character)
        index = string.index(after: index)
      }
    }
    return output
  }

  private static func decode(entity: Substring) -> String? {
    if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
      return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
    }
    if entity.hasPrefix("#") {
      return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
    }
    return namedEntities[String(entity)]
  }

  /// Returns the URL when the whole text is one web, mail or file link.
  public static func link(in text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 4_096,
          !trimmed.contains(where: { $0.isWhitespace }) else {
      return nil
    }
    let candidate = trimmed.lowercased().hasPrefix("www.") ? "https://\(trimmed)" : trimmed
    guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else {
      return nil
    }
    switch scheme {
    case "http", "https":
      return url.host?.contains(".") == true || url.host == "localhost" ? url : nil
    case "mailto", "ftp", "sftp", "ssh", "file":
      return url
    default:
      return nil
    }
  }

  public static func statistics(of text: String) -> (characters: Int, words: Int, lines: Int) {
    var words = 0
    var lines = text.isEmpty ? 0 : 1
    var inWord = false
    for character in text {
      if character.isNewline {
        lines += 1
      }
      if character.isWhitespace || character.isNewline {
        inWord = false
      } else if !inWord {
        inWord = true
        words += 1
      }
    }
    return (text.count, words, lines)
  }
}
