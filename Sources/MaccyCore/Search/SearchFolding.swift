import Foundation

/// Case- and diacritic-insensitive matching, the same as the ranker (Foundation
/// `.caseInsensitive` and `.diacriticInsensitive`) and close to the full-text index.
/// Terms that are too short for the trigram index use it in SQL (`maccy_contains`).
///
/// `String.range(of:options:)` takes 3.7 s for 100,000 rows of Hebrew text, so this
/// folds one scalar at a time with a table and searches the UTF-8 bytes directly.
enum SearchFolding {
  static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

  /// The table covers U+0000..<U+3000: Latin, Greek, Cyrillic, Hebrew, Arabic and
  /// the combining marks. Scalars above it (CJK, emoji) have no case and stay as they are.
  private static let tableSize: UInt32 = 0x3000
  private static let dropped: UInt32 = .max
  private static let multipleFlag: UInt32 = 0x8000_0000

  /// One folded scalar per entry, `dropped` for a diacritic, or `multipleFlag | index`
  /// into `multiples` for the rare scalar that folds to more than one.
  private static let tables: (single: [UInt32], multiples: [[UInt32]]) = {
    var single: [UInt32] = []
    var multiples: [[UInt32]] = []
    single.reserveCapacity(Int(tableSize))
    for value in 0..<tableSize {
      guard let scalar = Unicode.Scalar(value) else {
        single.append(value)
        continue
      }
      var folded = String(scalar).folding(options: options, locale: nil).unicodeScalars.map(\.value)
      // Foundation keeps a combining mark that has no base letter. Fold it after one,
      // so a decomposed "e\u{301}" or a Hebrew vowel point drops like in "é".
      if scalar.properties.generalCategory == .nonspacingMark,
         ("a" + String(scalar)).folding(options: options, locale: nil) == "a" {
        folded = []
      }
      switch folded.count {
      case 0:
        single.append(dropped)
      case 1:
        single.append(folded[0])
      default:
        single.append(multipleFlag | UInt32(multiples.count))
        multiples.append(folded)
      }
    }
    return (single, multiples)
  }()

  /// Calls `body` with each folded scalar of `value`: none for a diacritic.
  @inline(__always)
  static func fold(_ value: UInt32, _ body: (UInt32) -> Void) {
    if value < 0x80 {
      body(value >= 0x41 && value <= 0x5A ? value | 0x20 : value)
      return
    }
    guard value < tableSize else {
      body(value)
      return
    }
    let entry = tables.single[Int(value)]
    if entry == dropped {
      return
    }
    if entry & multipleFlag == 0 {
      body(entry)
    } else {
      tables.multiples[Int(entry & ~multipleFlag)].forEach(body)
    }
  }

  static func foldedScalars(_ string: String) -> [UInt32] {
    var output: [UInt32] = []
    for scalar in string.unicodeScalars {
      fold(scalar.value) { output.append($0) }
    }
    return output
  }

  /// The first folded scalar of a character, for the fuzzy matcher. `nil` for a
  /// character that is only diacritics.
  static func key(of character: Character) -> UInt32? {
    for scalar in character.unicodeScalars {
      var key: UInt32?
      fold(scalar.value) { key = key ?? $0 }
      if let key {
        return key
      }
    }
    return nil
  }
}

/// A search term, folded once, with its Knuth–Morris–Pratt table. One instance
/// serves every row of a query, so each row costs one pass over its bytes.
final class FoldedNeedle {
  let scalars: [UInt32]
  private let fallback: [Int]

  init(_ needle: String) {
    scalars = SearchFolding.foldedScalars(needle)
    var fallback = [Int](repeating: 0, count: scalars.count)
    var length = 0
    for index in scalars.indices.dropFirst() {
      while length > 0 && scalars[index] != scalars[length] {
        length = fallback[length - 1]
      }
      if scalars[index] == scalars[length] {
        length += 1
      }
      fallback[index] = length
    }
    self.fallback = fallback
  }

  /// `true` when the UTF-8 text contains the needle, case- and diacritic-insensitive.
  func isFound(in text: UnsafeBufferPointer<UInt8>) -> Bool {
    guard !scalars.isEmpty else {
      return true
    }
    let scalars = scalars
    let fallback = fallback
    var matched = 0
    var found = false
    var index = 0
    let count = text.count
    while index < count && !found {
      let lead = text[index]
      let length: Int
      var value: UInt32
      switch lead {
      case 0..<0x80:
        length = 1
        value = UInt32(lead)
      case 0xC0..<0xE0:
        length = 2
        value = UInt32(lead & 0x1F)
      case 0xE0..<0xF0:
        length = 3
        value = UInt32(lead & 0x0F)
      case 0xF0..<0xF8:
        length = 4
        value = UInt32(lead & 0x07)
      default:
        // A continuation byte without a lead byte. SQLite text from Swift is valid
        // UTF-8, so skip the byte rather than stop.
        index += 1
        continue
      }
      guard index + length <= count else {
        break
      }
      for offset in 1..<length {
        value = value << 6 | UInt32(text[index + offset] & 0x3F)
      }
      index += length
      SearchFolding.fold(value) { scalar in
        while matched > 0 && scalars[matched] != scalar {
          matched = fallback[matched - 1]
        }
        if scalars[matched] == scalar {
          matched += 1
          if matched == scalars.count {
            found = true
            matched = fallback[matched - 1]
          }
        }
      }
    }
    return found
  }

  func isFound(in string: String) -> Bool {
    var copy = string
    return copy.withUTF8 { isFound(in: $0) }
  }
}
