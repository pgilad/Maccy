import MaccyCore
import SwiftUI

struct PreviewPane: View {
  let model: PanelModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let row = model.selectedRow {
        content(for: row.summary)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        Divider()
        MetadataView(summary: row.summary, detail: model.detail?.summary.id == row.id ? model.detail : nil)
          .padding(14)
      } else {
        Spacer()
      }
    }
  }

  @ViewBuilder
  private func content(for summary: ClipSummary) -> some View {
    let detail = model.detail?.summary.id == summary.id ? model.detail : nil
    switch summary.kind {
    case .image:
      ImagePreview(image: model.previewImage, ocrText: detail?.ocrText)
    case .color:
      ColorPreview(text: detail?.text ?? summary.title)
    case .file:
      FilePreview(urls: detail?.fileURLs ?? [])
    case .link:
      LinkPreview(text: detail?.text ?? summary.title)
    case .text:
      TextPreview(text: detail?.text ?? summary.title, isTruncated: detail?.isTextTruncated ?? false)
    }
  }
}

struct TextPreview: View {
  static let swiftUILimit = 20_000

  let text: String
  let isTruncated: Bool

  var body: some View {
    if text.count > Self.swiftUILimit {
      LargeTextView(text: text)
        .padding(14)
    } else {
      VerticalScroll {
        VStack(alignment: .leading, spacing: 8) {
          Text(verbatim: text)
            .font(.system(size: 13))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          if isTruncated {
            Text("The preview shows the first 100,000 characters. Paste uses the full text.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(14)
      }
    }
  }
}

struct ImagePreview: View {
  let image: NSImage?
  let ocrText: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Group {
        if let image {
          Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .clipShape(.rect(cornerRadius: 6))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        } else {
          ProgressView()
            .controlSize(.small)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      if let ocrText, !ocrText.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Label("Text in Image", systemImage: "text.viewfinder")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          VerticalScroll {
            Text(verbatim: ocrText)
              .font(.caption)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 70)
        }
      }
    }
    .padding(14)
  }
}

struct ColorPreview: View {
  let text: String

  var body: some View {
    VStack(spacing: 12) {
      if let color = ParsedColor.parse(text) {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
          .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.15)))
          .frame(maxWidth: 220, maxHeight: 140)
        Text(color.hex)
          .font(.title2.monospaced())
          .textSelection(.enabled)
        Text(color.rgbDescription)
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      } else {
        Text(verbatim: text)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(14)
  }
}

struct LinkPreview: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let url = TextUtilities.link(in: text) {
        if let host = url.host() {
          Label(host, systemImage: "globe")
            .font(.headline)
        }
        Text(verbatim: url.absoluteString)
          .font(.system(size: 13).monospaced())
          .textSelection(.enabled)
          .foregroundStyle(.secondary)
      } else {
        Text(verbatim: text)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
  }
}

struct FilePreview: View {
  let urls: [URL]

  var body: some View {
    VerticalScroll {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(urls, id: \.self) { url in
          HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
              .resizable()
              .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
              Text(url.lastPathComponent)
                .lineLimit(1)
              Text(url.deletingLastPathComponent().path(percentEncoded: false))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
    }
  }
}

struct MetadataView: View {
  let summary: ClipSummary
  let detail: ClipDetail?

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
      if let app = summary.appName {
        row("Application") {
          HStack(spacing: 4) {
            if let icon = AppIcons.icon(for: summary.appBundleID) {
              Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }
            Text(app)
          }
        }
      }
      row("Type") {
        Text(summary.kind == .text && summary.hasRichText ? "Rich Text" : summary.kind.name)
      }
      if let width = summary.imageWidth, let height = summary.imageHeight {
        row("Dimensions") { Text("\(width) × \(height)") }
      }
      if summary.kind == .text || summary.kind == .link, let text = detail?.text {
        let stats = TextUtilities.statistics(of: text)
        row("Content") {
          Text("\(pluralized(stats.characters, "character")) · \(pluralized(stats.words, "word")) · \(pluralized(stats.lines, "line"))")
        }
      }
      row("Size") { Text(ByteCountFormatter.string(fromByteCount: Int64(summary.byteSize), countStyle: .file)) }
      row("Last Copied") { Text(summary.lastCopiedAt.formatted(.relative(presentation: .named))) }
      if summary.copyCount > 1 {
        row("First Copied") { Text(summary.firstCopiedAt.formatted(date: .abbreviated, time: .shortened)) }
        row("Times Copied") { Text("\(summary.copyCount)") }
      }
      if let expiresAt = summary.expiresAt {
        row("Deleted") {
          Text(expiresAt.formatted(.relative(presentation: .named)))
            .foregroundStyle(.orange)
        }
      }
    }
    .font(.caption)
  }

  private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      value()
        .lineLimit(1)
    }
  }
}

/// NSTextView for very long text. SwiftUI `Text` is slow above about 20,000 characters.
struct LargeTextView: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.drawsBackground = false
    scrollView.autohidesScrollers = true
    if let textView = scrollView.documentView as? NSTextView {
      textView.isEditable = false
      textView.isSelectable = true
      textView.drawsBackground = false
      textView.font = .systemFont(ofSize: 13)
      textView.textContainerInset = .zero
      textView.textContainer?.lineFragmentPadding = 0
      textView.string = text
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView, textView.string != text else {
      return
    }
    textView.string = text
    textView.scrollToBeginningOfDocument(nil)
  }
}
