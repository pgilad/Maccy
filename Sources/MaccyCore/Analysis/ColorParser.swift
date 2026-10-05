import Foundation

/// An sRGB color parsed from text such as `#ff9900`, `#f90`, `rgb(255, 153, 0)`.
public struct ParsedColor: Sendable, Hashable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public var alpha: Double

  public var hex: String {
    let components = [red, green, blue].map { Int(($0 * 255).rounded()) }
    let base = String(format: "#%02X%02X%02X", components[0], components[1], components[2])
    return alpha < 1 ? base + String(format: "%02X", Int((alpha * 255).rounded())) : base
  }

  public var rgbDescription: String {
    let components = [red, green, blue].map { Int(($0 * 255).rounded()) }
    if alpha < 1 {
      return "rgba(\(components[0]), \(components[1]), \(components[2]), \(String(format: "%.2f", alpha)))"
    }
    return "rgb(\(components[0]), \(components[1]), \(components[2]))"
  }

  public static func parse(_ text: String) -> ParsedColor? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count <= 40 else {
      return nil
    }
    return parseHex(trimmed) ?? parseRGB(trimmed)
  }

  private static func parseHex(_ text: String) -> ParsedColor? {
    guard text.hasPrefix("#") else {
      return nil
    }
    var digits = String(text.dropFirst())
    guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else {
      return nil
    }
    if digits.count <= 4 {
      digits = digits.map { "\($0)\($0)" }.joined()
    }
    guard let value = UInt64(digits, radix: 16) else {
      return nil
    }
    let hasAlpha = digits.count == 8
    let shift: UInt64 = hasAlpha ? 8 : 0
    return ParsedColor(
      red: Double((value >> (16 + shift)) & 0xFF) / 255,
      green: Double((value >> (8 + shift)) & 0xFF) / 255,
      blue: Double((value >> shift) & 0xFF) / 255,
      alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1
    )
  }

  private static func parseRGB(_ text: String) -> ParsedColor? {
    let lowercased = text.lowercased()
    guard lowercased.hasPrefix("rgb"), lowercased.hasSuffix(")"),
          let open = lowercased.firstIndex(of: "(") else {
      return nil
    }
    let inner = lowercased[lowercased.index(after: open)..<lowercased.index(before: lowercased.endIndex)]
    let parts = inner
      .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 3 || parts.count == 4 else {
      return nil
    }
    let channels = parts.prefix(3).compactMap { Double($0) }
    guard channels.count == 3, channels.allSatisfy({ (0...255).contains($0) }) else {
      return nil
    }
    var alpha = 1.0
    if parts.count == 4 {
      let raw = parts[3]
      if raw.hasSuffix("%"), let percent = Double(raw.dropLast()) {
        alpha = percent / 100
      } else if let value = Double(raw) {
        alpha = value
      } else {
        return nil
      }
      guard (0...1).contains(alpha) else {
        return nil
      }
    }
    return ParsedColor(red: channels[0] / 255, green: channels[1] / 255, blue: channels[2] / 255, alpha: alpha)
  }
}
