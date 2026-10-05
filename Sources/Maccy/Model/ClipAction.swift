import AppKit
import MaccyCore

/// One entry of the action panel (⌘K).
struct ClipAction: Identifiable {
  enum Role {
    case normal
    case destructive
  }

  let id: String
  let title: String
  let symbol: String
  let shortcut: String
  var role: Role = .normal
  let perform: () -> Void
}

extension PanelModel {
  var primaryActionTitle: String {
    switch controller.primaryDelivery {
    case .paste: targetApp?.name.map { "Paste to \($0)" } ?? "Paste"
    case .copy: "Copy to Clipboard"
    }
  }

  private var secondaryActionTitle: String {
    switch controller.secondaryDelivery {
    case .paste: targetApp?.name.map { "Paste to \($0)" } ?? "Paste"
    case .copy: "Copy to Clipboard"
    }
  }

  /// The actions for the selected item, filtered by the action search text.
  var actions: [ClipAction] {
    var list: [ClipAction] = []
    if let row = selectedRow {
      let kind = row.summary.kind
      let primarySymbol = controller.primaryDelivery == .paste ? "arrow.down.doc" : "doc.on.doc"
      let secondarySymbol = controller.secondaryDelivery == .paste ? "arrow.down.doc" : "doc.on.doc"
      list.append(ClipAction(id: "primary", title: primaryActionTitle, symbol: primarySymbol, shortcut: "↩") { [self] in
        performPrimary()
      })
      list.append(ClipAction(id: "secondary", title: secondaryActionTitle, symbol: secondarySymbol, shortcut: "⌘↩") { [self] in
        performSecondary()
      })
      if kind != .image {
        list.append(ClipAction(id: "plain", title: "Paste as Plain Text", symbol: "textformat", shortcut: "⌥↩") { [self] in
          pastePlainText()
        })
        list.append(ClipAction(id: "edit", title: "Edit and Paste…", symbol: "pencil", shortcut: "⌘E") { [self] in
          beginEditing()
        })
      }
      if kind == .link, let url = detail.flatMap({ TextUtilities.link(in: $0.text) }) {
        list.append(ClipAction(id: "open", title: "Open Link", symbol: "safari", shortcut: "⌘O") { [self] in
          controller.open(url)
        })
      }
      if kind == .file, let urls = detail?.fileURLs, !urls.isEmpty {
        list.append(ClipAction(id: "open", title: urls.count == 1 ? "Open File" : "Open Files", symbol: "arrow.up.forward.app", shortcut: "⌘O") { [self] in
          urls.forEach(controller.open)
        })
        list.append(ClipAction(id: "reveal", title: "Show in Finder", symbol: "folder", shortcut: "⇧⌘F") { [self] in
          controller.revealInFinder(urls)
        })
      }
      if kind == .image {
        list.append(ClipAction(id: "save", title: "Save Image…", symbol: "square.and.arrow.down", shortcut: "⌘S") { [self] in
          Task { await controller.saveImage(row.id) }
        })
        if let text = detail?.ocrText, !text.isEmpty {
          list.append(ClipAction(id: "ocr", title: "Copy Text in Image", symbol: "text.viewfinder", shortcut: "⇧⌘C") { [self] in
            controller.copyText(text)
          })
        }
      }
      list.append(ClipAction(
        id: "pin",
        title: row.summary.isPinned ? "Unpin" : "Pin",
        symbol: row.summary.isPinned ? "pin.slash" : "pin",
        shortcut: "⇧⌘P"
      ) { [self] in
        togglePin()
      })
      list.append(ClipAction(id: "delete", title: "Delete", symbol: "trash", shortcut: "⌘⌫", role: .destructive) { [self] in
        deleteSelected()
      })
    }
    list.append(ClipAction(id: "deleteAll", title: "Delete All Unpinned…", symbol: "trash.slash", shortcut: "⇧⌘⌫", role: .destructive) { [self] in
      onRequestClearHistory()
    })
    list.append(ClipAction(
      id: "pause",
      title: preferences.isPaused ? "Resume Capture" : "Pause Capture",
      symbol: preferences.isPaused ? "play.circle" : "pause.circle",
      shortcut: ""
    ) { [self] in
      togglePause()
    })
    list.append(ClipAction(id: "settings", title: "Settings…", symbol: "gearshape", shortcut: "⌘,") { [self] in
      onOpenSettings()
    })

    let filter = actionQuery.trimmingCharacters(in: .whitespaces)
    guard !filter.isEmpty else {
      return list
    }
    return list.filter { $0.title.localizedStandardContains(filter) }
  }

  func runSelectedAction() {
    let list = actions
    guard list.indices.contains(actionSelection) else {
      return
    }
    // Take the action first: closing the panel resets `actionSelection` to 0.
    let action = list[actionSelection]
    isActionPanelPresented = false
    action.perform()
  }

  func moveActionSelection(by offset: Int) {
    let count = actions.count
    guard count > 0 else {
      return
    }
    actionSelection = (actionSelection + offset + count) % count
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
