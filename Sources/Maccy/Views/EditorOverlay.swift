import SwiftUI

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
