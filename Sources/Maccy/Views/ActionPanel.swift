import SwiftUI

/// The ⌘K action list. Type to filter, ↑↓ to move, ↩ to run, ⎋ to close.
struct ActionPanel: View {
  @Bindable var model: PanelModel
  @FocusState private var focused: Bool
  @Environment(\.isSnapshot) private var isSnapshot

  var body: some View {
    let actions = model.actions
    VStack(spacing: 0) {
      VerticalScroll {
        VStack(spacing: 1) {
          ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
            ActionRow(action: action, isSelected: index == model.actionSelection)
              .onTapGesture {
                model.actionSelection = index
                model.runSelectedAction()
              }
          }
          if actions.isEmpty {
            Text("No Actions")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(10)
          }
        }
        .padding(5)
      }
      .frame(maxHeight: 300)
      .fixedSize(horizontal: false, vertical: true)
      Divider()
      Group {
        if isSnapshot {
          Text("Search actions…")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          TextField("Search actions…", text: $model.actionQuery)
            .textFieldStyle(.plain)
            .focused($focused)
        }
      }
      .font(.callout)
      .padding(.horizontal, 10)
      .frame(height: 34)
    }
    .frame(width: 300)
    .background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1)))
    .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    .onAppear {
      focused = true
    }
  }
}

struct ActionRow: View {
  let action: ClipAction
  let isSelected: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: action.symbol)
        .frame(width: 18)
        .foregroundStyle(isSelected ? .white : (action.role == .destructive ? .red : .secondary))
      Text(action.title)
        .foregroundStyle(isSelected ? .white : (action.role == .destructive ? .red : .primary))
      Spacer()
      if !action.shortcut.isEmpty {
        Text(action.shortcut)
          .font(.caption.monospaced())
          .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
      }
    }
    .font(.callout)
    .padding(.horizontal, 8)
    .frame(height: 28)
    .background(isSelected ? Color.accentColor : .clear, in: .rect(cornerRadius: 6))
    .contentShape(.rect)
  }
}

/// Edit the text of an item, then paste or copy the result. The history item does not change.
struct EditorOverlay: View {
  @Bindable var model: PanelModel
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Edit and Paste", systemImage: "pencil")
          .font(.headline)
        Spacer()
        Text("⌘↩ \(model.controller.primaryDelivery == .paste ? "Paste" : "Copy") · ⎋ Cancel")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(12)
      Divider()
      TextEditor(text: Binding(get: { model.editorText ?? "" }, set: { model.editorText = $0 }))
        .font(.system(size: 13).monospaced())
        .scrollContentBackground(.hidden)
        .padding(8)
        .focused($focused)
    }
    .background(.regularMaterial)
    .onAppear {
      focused = true
    }
  }
}
