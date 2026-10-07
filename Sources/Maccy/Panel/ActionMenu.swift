import AppKit

/// The actions (⌘K) as a native menu: sections, icons and key equivalents,
/// with the standard menu keyboard behavior (↑ ↓, ↩, ⎋, type to select).
/// macOS 27 usually hides the icons. Maccy keeps the system default.
enum ActionMenu {
  static func make(_ actions: [ClipAction]) -> NSMenu {
    let menu = NSMenu(title: "Actions")
    menu.autoenablesItems = false
    var previousSection: ClipAction.Section?
    for action in actions {
      if let previousSection, previousSection != action.section {
        menu.addItem(.separator())
      }
      previousSection = action.section
      let item = NSMenuItem(title: action.title, action: #selector(ActionTarget.run(_:)), keyEquivalent: action.keyEquivalent)
      item.target = ActionTarget.shared
      item.representedObject = ActionTarget.Handler(action.perform)
      item.keyEquivalentModifierMask = action.modifiers
      item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
      item.identifier = NSUserInterfaceItemIdentifier(action.id)
      menu.addItem(item)
    }
    return menu
  }

  /// Shows the menu above the bottom-right corner of `view` (the Actions button).
  static func popUp(_ menu: NSMenu, in view: NSView, footerHeight: CGFloat) {
    let size = menu.size
    let x = max(view.bounds.minX + 8, view.bounds.maxX - size.width - 8)
    let bottom = footerHeight + 4
    // The location is the top-left corner of the menu, in view coordinates.
    let y = view.isFlipped ? view.bounds.maxY - bottom - size.height : view.bounds.minY + bottom + size.height
    menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: view)
  }
}

/// Runs the closure stored in a menu item. Each item keeps its own closure in
/// `representedObject`, so the shared target needs no state.
final class ActionTarget: NSObject {
  static let shared = ActionTarget()

  final class Handler {
    let perform: () -> Void

    init(_ perform: @escaping () -> Void) {
      self.perform = perform
    }
  }

  @objc func run(_ sender: NSMenuItem) {
    (sender.representedObject as? Handler)?.perform()
  }
}
