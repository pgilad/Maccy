import AppKit
import MaccyCore

/// Writes a history item back to a pasteboard.
final class PasteboardWriter {
  private let pasteboard: NSPasteboard
  /// The pasteboard does not retain data providers, so keep them until the next write.
  private var providers: [TIFFProvider] = []
  /// Receives the change count of each write, so the monitor can skip Maccy's own changes.
  var didWrite: (Int) -> Void = { _ in }

  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
  }

  /// Returns the new change count.
  @discardableResult
  func write(_ representations: [Representation], plainText: String? = nil, plainTextOnly: Bool = false) -> Int {
    providers.removeAll()
    var selected = representations
    if plainTextOnly {
      selected = representations.filter { $0.type == PasteboardTypes.string || $0.type == PasteboardTypes.fileURL }
      if !selected.contains(where: { $0.type == PasteboardTypes.string }), let plainText, !plainText.isEmpty {
        selected.insert(Representation(type: PasteboardTypes.string, data: Data(plainText.utf8)), at: 0)
      }
      // An image has no plain text. Write it unchanged rather than an empty pasteboard.
      if selected.isEmpty {
        selected = representations
      }
    }

    let groups = Dictionary(grouping: selected, by: \.itemIndex).sorted { $0.key < $1.key }
    var items: [NSPasteboardItem] = []
    for (offset, group) in groups.enumerated() {
      let item = NSPasteboardItem()
      for representation in group.value {
        item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
      }
      // Some apps read only TIFF. Make it on demand from the stored PNG.
      let types = Set(group.value.map(\.type))
      if !types.contains(PasteboardTypes.tiff),
         let image = group.value.first(where: { PasteboardTypes.images.contains($0.type) }) {
        let provider = TIFFProvider(imageData: image.data)
        item.setDataProvider(provider, forTypes: [.tiff])
        providers.append(provider)
      }
      if offset == 0 {
        item.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardTypes.fromMaccy))
        item.setString(Bundle.main.bundleIdentifier ?? "com.pgilad.Maccy", forType: NSPasteboard.PasteboardType(PasteboardTypes.source))
      }
      items.append(item)
    }

    pasteboard.clearContents()
    pasteboard.writeObjects(items)
    let changeCount = pasteboard.changeCount
    didWrite(changeCount)
    return changeCount
  }

  @discardableResult
  func write(string: String) -> Int {
    write([Representation(type: PasteboardTypes.string, data: Data(string.utf8))])
  }

  func clear() {
    didWrite(pasteboard.clearContents())
  }
}

private nonisolated final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
  let imageData: Data

  init(imageData: Data) {
    self.imageData = imageData
  }

  func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
    if let tiff = ImageProcessing.tiffData(from: imageData) {
      item.setData(tiff, forType: type)
    }
  }
}
