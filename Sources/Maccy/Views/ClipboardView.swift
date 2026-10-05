import MaccyCore
import SwiftUI

/// The panel: search on top, the list on the left, the preview on the right.
struct ClipboardView: View {
  @Bindable var model: PanelModel
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      SearchBar(model: model, focused: $searchFocused)
      Divider()
      HStack(spacing: 0) {
        ClipListView(model: model)
          .frame(width: listWidth)
        Divider()
        PreviewPane(model: model)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxHeight: .infinity)
      Divider()
      FooterBar(model: model)
    }
    .overlay(alignment: .bottomTrailing) {
      if model.isActionPanelPresented {
        ActionPanel(model: model)
          .padding(.trailing, 10)
          .padding(.bottom, 44)
          .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottomTrailing)))
      }
    }
    .overlay {
      if model.editorText != nil {
        EditorOverlay(model: model)
      }
    }
    .animation(.easeOut(duration: 0.12), value: model.isActionPanelPresented)
    .background {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(.clear)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
    .clipShape(.rect(cornerRadius: 16, style: .continuous))
    .onChange(of: model.openCount, initial: true) {
      searchFocused = true
    }
    .onChange(of: model.isActionPanelPresented) { _, presented in
      if !presented {
        searchFocused = true
      }
    }
    .onChange(of: model.editorText == nil) { _, closed in
      if closed {
        searchFocused = true
      }
    }
  }

  private var listWidth: CGFloat {
    max(260, min(420, model.preferences.windowSize.width * 0.42))
  }
}

struct SearchBar: View {
  @Bindable var model: PanelModel
  var focused: FocusState<Bool>.Binding
  @Environment(\.isSnapshot) private var isSnapshot

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.secondary)
      if isSnapshot {
        Text(model.query.isEmpty ? "Search clipboard history" : model.query)
          .font(.system(size: 18))
          .foregroundStyle(model.query.isEmpty ? .tertiary : .primary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        TextField("Search clipboard history", text: $model.query)
          .textFieldStyle(.plain)
          .font(.system(size: 18))
          .focused(focused)
          .disabled(model.isActionPanelPresented || model.editorText != nil)
          .accessibilityIdentifier("search")
      }
      if let error = model.searchError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
      KindFilterMenu(model: model)
    }
    .padding(.horizontal, 16)
    .frame(height: 52)
  }
}

struct KindFilterMenu: View {
  @Bindable var model: PanelModel
  @Environment(\.isSnapshot) private var isSnapshot

  var body: some View {
    if isSnapshot {
      label
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: .rect(cornerRadius: 6))
    } else {
      menu
    }
  }

  private var label: some View {
    HStack(spacing: 4) {
      Image(systemName: model.kindFilter?.symbolName ?? "square.grid.2x2")
      Text(model.kindFilter?.pluralName ?? "All Types")
    }
    .font(.callout)
  }

  private var menu: some View {
    Menu {
      Picker("Type", selection: $model.kindFilter) {
        Label("All Types", systemImage: "square.grid.2x2").tag(ClipKind?.none)
        Divider()
        ForEach(ClipKind.allCases) { kind in
          Label(kind.pluralName, systemImage: kind.symbolName).tag(Optional(kind))
        }
      }
      .pickerStyle(.inline)
    } label: {
      label
    }
    .menuStyle(.button)
    .buttonStyle(.bordered)
    .controlSize(.small)
    .fixedSize()
    .help("Filter by type (⌘P)")
  }
}
