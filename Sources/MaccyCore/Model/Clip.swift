import Foundation

/// The kind of a history item. The raw values are stored in the database.
public enum ClipKind: Int, Sendable, CaseIterable, Identifiable, Codable {
  case text = 0
  case link = 1
  case image = 2
  case file = 3
  case color = 4

  public var id: Int { rawValue }

  public var name: String {
    switch self {
    case .text: "Text"
    case .link: "Link"
    case .image: "Image"
    case .file: "File"
    case .color: "Color"
    }
  }

  public var pluralName: String {
    switch self {
    case .text: "Text"
    case .link: "Links"
    case .image: "Images"
    case .file: "Files"
    case .color: "Colors"
    }
  }

  public var symbolName: String {
    switch self {
    case .text: "text.alignleft"
    case .link: "link"
    case .image: "photo"
    case .file: "doc"
    case .color: "paintpalette"
    }
  }

  /// Parses the value of a `type:` search token.
  public init?(searchToken: String) {
    switch searchToken.lowercased() {
    case "text", "txt": self = .text
    case "link", "links", "url", "urls": self = .link
    case "image", "images", "img", "picture": self = .image
    case "file", "files": self = .file
    case "color", "colors", "colour", "colours": self = .color
    default: return nil
    }
  }
}

/// One pasteboard representation (one UTI of one pasteboard item).
public struct Representation: Sendable, Hashable {
  /// The index of the pasteboard item. Multi-file copies have one item per file.
  public var itemIndex: Int
  public var type: String
  public var data: Data

  public init(itemIndex: Int = 0, type: String, data: Data) {
    self.itemIndex = itemIndex
    self.type = type
    self.data = data
  }
}

/// Raw data read from the pasteboard, before analysis.
public struct CapturedClip: Sendable {
  public var representations: [Representation]
  public var sourceBundleID: String?
  public var sourceAppName: String?
  public var isUniversalClipboard: Bool
  public var capturedAt: Date

  public init(
    representations: [Representation],
    sourceBundleID: String? = nil,
    sourceAppName: String? = nil,
    isUniversalClipboard: Bool = false,
    capturedAt: Date = .now
  ) {
    self.representations = representations
    self.sourceBundleID = sourceBundleID
    self.sourceAppName = sourceAppName
    self.isUniversalClipboard = isUniversalClipboard
    self.capturedAt = capturedAt
  }
}

/// A lightweight history row. The list holds only these values.
public struct ClipSummary: Sendable, Identifiable, Hashable {
  public var id: Int64
  public var kind: ClipKind
  public var title: String
  public var appBundleID: String?
  public var appName: String?
  public var firstCopiedAt: Date
  public var lastCopiedAt: Date
  public var copyCount: Int
  public var pinnedAt: Date?
  public var byteSize: Int
  public var imageWidth: Int?
  public var imageHeight: Int?
  public var hasRichText: Bool
  public var fileCount: Int
  public var isSensitive: Bool
  public var expiresAt: Date?

  public var isPinned: Bool { pinnedAt != nil }

  public init(
    id: Int64,
    kind: ClipKind,
    title: String,
    appBundleID: String? = nil,
    appName: String? = nil,
    firstCopiedAt: Date = .now,
    lastCopiedAt: Date = .now,
    copyCount: Int = 1,
    pinnedAt: Date? = nil,
    byteSize: Int = 0,
    imageWidth: Int? = nil,
    imageHeight: Int? = nil,
    hasRichText: Bool = false,
    fileCount: Int = 0,
    isSensitive: Bool = false,
    expiresAt: Date? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.appBundleID = appBundleID
    self.appName = appName
    self.firstCopiedAt = firstCopiedAt
    self.lastCopiedAt = lastCopiedAt
    self.copyCount = copyCount
    self.pinnedAt = pinnedAt
    self.byteSize = byteSize
    self.imageWidth = imageWidth
    self.imageHeight = imageHeight
    self.hasRichText = hasRichText
    self.fileCount = fileCount
    self.isSensitive = isSensitive
    self.expiresAt = expiresAt
  }
}

/// Full data for the preview pane.
public struct ClipDetail: Sendable {
  public var summary: ClipSummary
  /// The plain text. It is capped at `ClipAnalyzer.maxIndexedTextLength` characters.
  public var text: String
  public var isTextTruncated: Bool
  public var ocrText: String?
  public var fileURLs: [URL]
  public var representationTypes: [String]
}

/// One search result with the title ranges that matched.
public struct SearchHit: Sendable, Identifiable, Hashable {
  public var summary: ClipSummary
  public var titleMatches: [Range<Int>]
  public var score: Double

  public var id: Int64 { summary.id }

  public init(summary: ClipSummary, titleMatches: [Range<Int>] = [], score: Double = 0) {
    self.summary = summary
    self.titleMatches = titleMatches
    self.score = score
  }
}
