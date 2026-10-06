import MaccyCore
import SwiftUI

struct ClipListView: View {
  @Bindable var model: PanelModel

  var body: some View {
    ScrollViewReader { proxy in
      VerticalScroll {
        LazyVStack(alignment: .leading, spacing: 1) {
          if model.rows.isEmpty && !model.isSearching {
            EmptyListView(hasQuery: !model.query.isEmpty || model.kindFilter != nil)
          }
          ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, hit in
            if let header = sectionHeader(at: index) {
              Text(header)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, index == 0 ? 4 : 10)
                .padding(.bottom, 2)
            }
            ClipRow(
              hit: hit,
              index: index,
              isSelected: hit.id == model.selectedID,
              showShortcut: model.isCommandHeld,
              showAppIcon: model.preferences.showAppIcons,
              thumbnail: hit.summary.kind == .image ? model.thumbnail(for: hit.id) : nil
            )
            .id(hit.id)
            .onTapGesture(count: 2) {
              model.selectedID = hit.id
              model.performPrimary()
            }
            .simultaneousGesture(TapGesture().onEnded {
              model.selectedID = hit.id
            })
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ClipboardView.coordinateSpace)) } action: { frame in
              model.rowFrames[hit.id] = frame
            }
            .onDisappear {
              model.rowFrames[hit.id] = nil
            }
            .accessibilityAction {
              model.selectedID = hit.id
              model.performPrimary()
            }
            .accessibilityAction(.showMenu) {
              Task {
                await model.select(hit.id)
                model.onShowActions()
              }
            }
          }
        }
        .padding(6)
      }
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ClipboardView.coordinateSpace)) } action: { frame in
        model.listFrame = frame
      }
      .onChange(of: model.selectedID) { _, id in
        if let id {
          proxy.scrollTo(id)
        }
        announceSelection()
      }
    }
  }

  /// Focus stays in the search field while ↑ ↓ move the selection, so VoiceOver
  /// does not move with it. Read the selected item aloud, like Spotlight.
  private func announceSelection() {
    guard NSWorkspace.shared.isVoiceOverEnabled, let row = model.selectedRow else {
      return
    }
    NSAccessibility.post(
      element: NSApp.keyWindow ?? NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: ClipRow.accessibilityLabel(for: row.summary),
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
  }

  /// "Pinned" above the pinned rows and "Recent" above the others, when no search runs.
  private func sectionHeader(at index: Int) -> String? {
    guard model.query.isEmpty else {
      return nil
    }
    let rows = model.rows
    let isPinned = rows[index].summary.isPinned
    let previousPinned = index > 0 ? rows[index - 1].summary.isPinned : nil
    guard previousPinned != isPinned else {
      return nil
    }
    if isPinned {
      return "Pinned"
    }
    return rows.first?.summary.isPinned == true ? "Recent" : nil
  }
}

struct EmptyListView: View {
  let hasQuery: Bool

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: hasQuery ? "magnifyingglass" : "clipboard")
        .font(.system(size: 28))
        .foregroundStyle(.tertiary)
      Text(hasQuery ? "No Matches" : "No Copies Yet")
        .font(.headline)
        .foregroundStyle(.secondary)
      Text(hasQuery ? "Try fewer words, or a filter such as type:image." : "Copy something, and it appears here.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 60)
  }
}

struct ClipRow: View {
  let hit: SearchHit
  let index: Int
  let isSelected: Bool
  let showShortcut: Bool
  let showAppIcon: Bool
  let thumbnail: NSImage?

  var body: some View {
    HStack(spacing: 9) {
      leadingIcon
        .frame(width: 22, height: 22)
      HighlightedText(text: hit.summary.title.isEmpty ? " " : hit.summary.title, ranges: hit.titleMatches, isSelected: isSelected)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 4)
      if hit.summary.isSensitive {
        Image(systemName: "lock.fill")
          .font(.caption2)
          .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
          .help("Looks like a secret")
      }
      if hit.summary.isPinned {
        Image(systemName: "pin.fill")
          .font(.caption2)
          .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
      }
      if showShortcut && index < 9 {
        Text("⌘\(index + 1)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
      }
    }
    .padding(.horizontal, 8)
    .frame(height: 32)
    .foregroundStyle(isSelected ? .white : .primary)
    .background {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(isSelected ? Color.accentColor : .clear)
    }
    .contentShape(.rect)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.accessibilityLabel(for: hit.summary))
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  @ViewBuilder
  private var leadingIcon: some View {
    switch hit.summary.kind {
    case .image:
      if let thumbnail {
        Image(nsImage: thumbnail)
          .resizable()
          .scaledToFill()
          .frame(width: 22, height: 22)
          .clipShape(.rect(cornerRadius: 4))
      } else {
        kindSymbol
      }
    case .color:
      if let color = ParsedColor.parse(hit.summary.title) {
        RoundedRectangle(cornerRadius: 5)
          .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
          .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.2)))
          .frame(width: 18, height: 18)
      } else {
        kindSymbol
      }
    default:
      if showAppIcon, let icon = AppIcons.icon(for: hit.summary.appBundleID) {
        Image(nsImage: icon)
          .resizable()
          .frame(width: 20, height: 20)
      } else {
        kindSymbol
      }
    }
  }

  private var kindSymbol: some View {
    Image(systemName: hit.summary.kind.symbolName)
      .font(.system(size: 13))
      .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
  }

  static func accessibilityLabel(for summary: ClipSummary) -> String {
    var parts = [summary.kind.name, summary.title]
    if let app = summary.appName {
      parts.append(app)
    }
    if summary.isPinned {
      parts.append("pinned")
    }
    // The lock icon has no VoiceOver text, so say it here, with the delete time.
    if summary.isSensitive {
      parts.append("looks like a secret")
      if let expiresAt = summary.expiresAt {
        parts.append("deleted \(expiresAt.formatted(.relative(presentation: .named)))")
      }
    }
    return parts.joined(separator: ", ")
  }
}

/// A one-line title with the matched ranges in bold.
struct HighlightedText: View {
  let text: String
  let ranges: [Range<Int>]
  let isSelected: Bool

  var body: some View {
    Text(attributed)
  }

  private var attributed: AttributedString {
    var string = AttributedString(text)
    let count = string.characters.count
    for range in ranges where range.lowerBound < count {
      let start = string.characters.index(string.startIndex, offsetBy: range.lowerBound)
      let end = string.characters.index(start, offsetBy: min(range.count, count - range.lowerBound))
      string[start..<end].inlinePresentationIntent = .stronglyEmphasized
      if !isSelected {
        string[start..<end].foregroundColor = .accentColor
      }
    }
    return string
  }
}
