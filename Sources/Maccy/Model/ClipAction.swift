import AppKit
import MaccyCore

/// One entry of the actions menu (⌘K). The key equivalent is shown in the
/// menu; PanelController handles the same keys while the menu is closed.
struct ClipAction: Identifiable {
  enum Section: Int {
    case deliver, open, item, app
  }

  let id: String
  let title: String
  let symbol: String
  let section: Section
  var keyEquivalent = ""
  var modifiers: NSEvent.ModifierFlags = []
  let perform: () -> Void
}

extension PanelModel {
  var primaryActionTitle: String {
    title(for: controller.primaryDelivery)
  }

  private func title(for delivery: HistoryController.Delivery) -> String {
    switch delivery {
    case .paste: targetApp?.name.map { "Paste to \($0)" } ?? "Paste"
    case .copy: "Copy to Clipboard"
    }
  }

  private func symbol(for delivery: HistoryController.Delivery) -> String {
    delivery == .paste ? "arrow.down.doc" : "doc.on.doc"
  }

  /// The actions for the selected item, in menu order.
  var actions: [ClipAction] {
    var list: [ClipAction] = []
    if let row = selectedRow {
      let kind = row.summary.kind
      list.append(ClipAction(
        id: "primary", title: title(for: controller.primaryDelivery), symbol: symbol(for: controller.primaryDelivery),
        section: .deliver, keyEquivalent: "\r"
      ) { [self] in performPrimary() })
      list.append(ClipAction(
        id: "secondary", title: title(for: controller.secondaryDelivery), symbol: symbol(for: controller.secondaryDelivery),
        section: .deliver, keyEquivalent: "\r", modifiers: .command
      ) { [self] in performSecondary() })
      if kind != .image {
        list.append(ClipAction(
          id: "plain", title: "Paste as Plain Text", symbol: "textformat", section: .deliver,
          keyEquivalent: "\r", modifiers: .option
        ) { [self] in pastePlainText() })
        list.append(ClipAction(
          id: "edit", title: "Edit and Paste…", symbol: "pencil", section: .deliver, keyEquivalent: "e", modifiers: .command
        ) { [self] in beginEditing() })
      }
      if kind == .link, let url = detail.flatMap({ TextUtilities.link(in: $0.text) }) {
        list.append(ClipAction(
          id: "open", title: "Open Link", symbol: "safari", section: .open, keyEquivalent: "o", modifiers: .command
        ) { [self] in controller.open(url) })
      }
      if kind == .file, let urls = detail?.fileURLs, !urls.isEmpty {
        list.append(ClipAction(
          id: "open", title: urls.count == 1 ? "Open File" : "Open Files", symbol: "arrow.up.forward.app",
          section: .open, keyEquivalent: "o", modifiers: .command
        ) { [self] in urls.forEach(controller.open) })
        list.append(ClipAction(
          id: "reveal", title: "Show in Finder", symbol: "folder", section: .open,
          keyEquivalent: "f", modifiers: [.command, .shift]
        ) { [self] in controller.revealInFinder(urls) })
      }
      if kind == .image {
        list.append(ClipAction(
          id: "save", title: "Save Image…", symbol: "square.and.arrow.down", section: .open,
          keyEquivalent: "s", modifiers: .command
        ) { [self] in Task { await controller.saveImage(row.id) } })
        if let text = detail?.ocrText, !text.isEmpty {
          list.append(ClipAction(
            id: "ocr", title: "Copy Text in Image", symbol: "text.viewfinder", section: .open,
            keyEquivalent: "c", modifiers: [.command, .shift]
          ) { [self] in controller.copyText(text) })
        }
      }
      list.append(ClipAction(
        id: "pin", title: row.summary.isPinned ? "Unpin" : "Pin", symbol: row.summary.isPinned ? "pin.slash" : "pin",
        section: .item, keyEquivalent: "p", modifiers: [.command, .shift]
      ) { [self] in togglePin() })
      list.append(ClipAction(
        id: "delete", title: "Delete", symbol: "trash", section: .item, keyEquivalent: "\u{8}", modifiers: .command
      ) { [self] in deleteSelected() })
    }
    list.append(ClipAction(
      id: "deleteAll", title: "Delete All Unpinned…", symbol: "trash.slash", section: .item,
      keyEquivalent: "\u{8}", modifiers: [.command, .shift]
    ) { [self] in onRequestClearHistory() })
    list.append(ClipAction(
      id: "pause", title: preferences.isPaused ? "Resume Capture" : "Pause Capture",
      symbol: preferences.isPaused ? "play.circle" : "pause.circle", section: .app
    ) { [self] in togglePause() })
    list.append(ClipAction(
      id: "settings", title: "Settings…", symbol: "gearshape", section: .app, keyEquivalent: ",", modifiers: .command
    ) { [self] in onOpenSettings() })
    return list
  }

  func togglePause() {
    preferences.refreshPauseState()
    if preferences.isPaused {
      preferences.ignoreEvents = false
      preferences.pauseUntil = nil
    } else {
      preferences.ignoreEvents = true
    }
  }
}
