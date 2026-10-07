import SwiftUI

struct FooterBar: View {
  static let height: CGFloat = 38

  let model: PanelModel

  var body: some View {
    HStack(spacing: 10) {
      status
      Spacer(minLength: 8)
      if model.selectedRow != nil || !model.query.isEmpty {
        HintButton(title: model.selectedRow == nil ? "Copy Search Text" : model.primaryActionTitle, keys: "↩") {
          model.performPrimary()
        }
        Divider().frame(height: 16)
      }
      HintButton(title: "Actions", keys: "⌘K") {
        model.onShowActions()
      }
    }
    .padding(.horizontal, 12)
    .frame(height: Self.height)
  }

  @ViewBuilder
  private var status: some View {
    let preferences = model.preferences
    if let toast = model.controller.toast {
      Label(toast, systemImage: "info.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    } else if Permissions.pasteboardAccessNeedsAttention {
      // "Deny" stops the history. "Ask" shows a system alert at each copy.
      let isDenied = Permissions.pasteboardAccess == .alwaysDeny
      Button {
        Permissions.openPasteboardSettings()
      } label: {
        Label(
          isDenied ? "Allow Paste from Other Apps to save copies" : "Set Paste from Other Apps to Always",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }
      .buttonStyle(.plain)
      .help(
        (isDenied ? "macOS does not let Maccy read what you copy in other apps. " : "macOS asks before Maccy reads each copy. ")
          + "Set Maccy to Always in Privacy & Security › Paste from Other Apps, then restart Maccy."
      )
    } else if preferences.pasteAutomatically && !Paster.isTrusted {
      Button {
        Permissions.openAccessibilitySettings()
      } label: {
        Label("Allow \(Permissions.accessibilityName) to paste", systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      .buttonStyle(.plain)
      .help("Without this permission, Maccy copies the item, and you press ⌘V.")
    } else if preferences.isPaused {
      Button {
        model.togglePause()
      } label: {
        Label("Capture paused · Resume", systemImage: "pause.circle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      .buttonStyle(.plain)
    } else {
      Text(model.rows.count == PanelModel.rowLimit ? "\(PanelModel.rowLimit)+ items" : "\(model.rows.count) items")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

struct HintButton: View {
  let title: String
  let keys: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title)
          .lineLimit(1)
        KeyCap(keys)
      }
      .font(.caption)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
  }
}

struct KeyCap: View {
  let keys: String

  init(_ keys: String) {
    self.keys = keys
  }

  var body: some View {
    Text(keys)
      .font(.caption.monospaced())
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(.quaternary, in: .rect(cornerRadius: 4))
  }
}
