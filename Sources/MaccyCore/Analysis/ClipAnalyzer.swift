import AppKit
import CryptoKit
import Foundation

/// The result of the analysis of one copy. It is ready to store.
public struct AnalyzedClip: Sendable {
  public var kind: ClipKind
  public var title: String
  /// Searchable plain text, capped at `ClipAnalyzer.maxIndexedTextLength` characters.
  public var text: String
  public var isTextTruncated: Bool
  /// SHA-256 of the canonical content. Two copies with the same hash are one item.
  public var contentHash: Data
  public var representations: [Representation]
  public var hasRichText: Bool
  public var fileCount: Int
  public var imageWidth: Int?
  public var imageHeight: Int?
  /// The image that the thumbnail and OCR use.
  public var primaryImage: Data?
  public var byteSize: Int
  /// The name of the secret rule that matched, if any.
  public var detectedSecret: String?
  public var sourceBundleID: String?
  public var sourceAppName: String?
  public var capturedAt: Date
}

public enum ClipAnalyzer {
  public static let maxIndexedTextLength = 100_000

  /// Returns `nil` when the copy has nothing worth saving.
  public static func analyze(_ clip: CapturedClip) -> AnalyzedClip? {
    var representations = clip.representations.filter { !$0.data.isEmpty }
    guard !representations.isEmpty else {
      return nil
    }

    let fileURLs = representations
      .filter { $0.type == PasteboardTypes.fileURL }
      .compactMap { URL(dataRepresentation: $0.data, relativeTo: nil, isAbsolute: true) }

    // Keep one image representation. Convert TIFF (large and uncompressed) to PNG.
    var primaryImage: Data?
    if let image = PasteboardTypes.images.lazy.compactMap({ type in
      representations.first { $0.type == type }
    }).first {
      representations.removeAll { PasteboardTypes.images.contains($0.type) }
      if image.type == PasteboardTypes.tiff, let png = ImageProcessing.pngData(from: image.data) {
        representations.append(Representation(itemIndex: image.itemIndex, type: PasteboardTypes.png, data: png))
        primaryImage = png
      } else {
        representations.append(image)
        primaryImage = image.data
      }
    }

    let plainText = plainText(in: representations)
    let trimmed = plainText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let hasRichText = representations.contains { $0.type == PasteboardTypes.rtf || $0.type == PasteboardTypes.html }

    let kind: ClipKind
    if !fileURLs.isEmpty {
      kind = .file
    } else if primaryImage != nil && (trimmed.isEmpty || (TextUtilities.link(in: trimmed) != nil && !hasRichText)) {
      kind = .image
    } else if trimmed.isEmpty {
      return nil
    } else if TextUtilities.link(in: trimmed) != nil {
      kind = .link
    } else if ParsedColor.parse(trimmed) != nil {
      kind = .color
    } else {
      kind = .text
    }

    if kind != .image {
      primaryImage = nil
    }

    var searchable: String
    switch kind {
    case .file:
      searchable = fileURLs.map { $0.isFileURL ? $0.path(percentEncoded: false) : $0.absoluteString }
        .joined(separator: "\n")
    case .image:
      searchable = trimmed
    default:
      searchable = plainText ?? ""
    }
    var isTruncated = false
    if searchable.count > maxIndexedTextLength {
      searchable = String(searchable.prefix(maxIndexedTextLength))
      isTruncated = true
    }

    let imageSize = primaryImage.flatMap(ImageProcessing.pixelSize(of:))
    let title = makeTitle(kind: kind, text: trimmed, fileURLs: fileURLs, imageSize: imageSize)
    let hash = contentHash(kind: kind, text: plainText ?? "", fileURLs: fileURLs, image: primaryImage)
    let detectedSecret = (kind == .text || kind == .link) ? SecretDetector.detect(in: plainText ?? "") : nil

    return AnalyzedClip(
      kind: kind,
      title: title,
      text: searchable,
      isTextTruncated: isTruncated,
      contentHash: hash,
      representations: representations,
      hasRichText: hasRichText && kind == .text,
      fileCount: fileURLs.count,
      imageWidth: imageSize?.width,
      imageHeight: imageSize?.height,
      primaryImage: primaryImage,
      byteSize: representations.reduce(0) { $0 + $1.data.count },
      detectedSecret: detectedSecret,
      sourceBundleID: clip.sourceBundleID,
      sourceAppName: clip.isUniversalClipboard ? "iCloud" : clip.sourceAppName,
      capturedAt: clip.capturedAt
    )
  }

  /// The best plain text: the string flavor, else RTF, else HTML.
  public static func plainText(in representations: [Representation]) -> String? {
    if let data = representations.first(where: { $0.type == PasteboardTypes.string })?.data,
       let string = String(data: data, encoding: .utf8), !string.isEmpty {
      return string
    }
    if let data = representations.first(where: { $0.type == PasteboardTypes.rtf })?.data,
       let attributed = NSAttributedString(rtf: data, documentAttributes: nil),
       !attributed.string.isEmpty {
      return attributed.string
    }
    if let data = representations.first(where: { $0.type == PasteboardTypes.html })?.data,
       let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) {
      let text = TextUtilities.plainText(fromHTML: html)
      return text.isEmpty ? nil : text
    }
    if let data = representations.first(where: { $0.type == PasteboardTypes.url })?.data {
      return String(data: data, encoding: .utf8)
    }
    return nil
  }

  static func makeTitle(kind: ClipKind, text: String, fileURLs: [URL], imageSize: (width: Int, height: Int)?) -> String {
    switch kind {
    case .image:
      if let imageSize {
        return "Image (\(imageSize.width)×\(imageSize.height))"
      }
      return "Image"
    case .file:
      let names = fileURLs.map { $0.isFileURL ? $0.lastPathComponent : $0.absoluteString }
      if names.count == 1 {
        return names[0]
      }
      return TextUtilities.title(from: "\(names.count) files: " + names.joined(separator: ", "))
    case .text, .link, .color:
      return TextUtilities.title(from: text)
    }
  }

  static func contentHash(kind: ClipKind, text: String, fileURLs: [URL], image: Data?) -> Data {
    var hasher = SHA256()
    switch kind {
    case .image:
      hasher.update(data: Data("image\0".utf8))
      if let image {
        hasher.update(data: image)
      }
    case .file:
      hasher.update(data: Data("file\0".utf8))
      hasher.update(data: Data(fileURLs.map(\.absoluteString).joined(separator: "\n").utf8))
    case .text, .link, .color:
      hasher.update(data: Data("text\0".utf8))
      hasher.update(data: Data(text.utf8))
    }
    return Data(hasher.finalize())
  }
}
