import AppKit
import MaccyCore
import Observation

/// The state of the clipboard panel: query, filter, results, selection and preview.
@Observable
final class PanelModel {
  static let rowLimit = 300
  nonisolated static let previewPixelSize = 1_600

  let controller: HistoryController
  var preferences: Preferences { controller.preferences }

  var query = "" {
    didSet {
      if query != oldValue {
        search(resetSelection: true)
      }
    }
  }
  var kindFilter: ClipKind? {
    didSet {
      if kindFilter != oldValue {
        search(resetSelection: true)
      }
    }
  }

  private(set) var rows: [SearchHit] = []
  private(set) var isSearching = false
  private(set) var searchError: String?
  var selectedID: Int64? {
    didSet {
      if selectedID != oldValue {
        loadDetail()
      }
    }
  }
  private(set) var detail: ClipDetail?
  private(set) var previewImage: NSImage?
  private(set) var thumbnails: [Int64: NSImage] = [:]

  /// The app that receives the paste, shown as "Paste to …".
  var targetApp: SourceApp?
  /// Increments on each open, so the view focuses the search field.
  private(set) var openCount = 0
  var isCommandHeld = false

  /// The text in the "Edit and Paste" editor, or `nil` when the editor is closed.
  var editorText: String?

  /// Row frames and the visible list frame in the panel (top-left origin), for
  /// right-click hit testing. The views write them. Nothing observes them.
  @ObservationIgnored var rowFrames: [Int64: CGRect] = [:]
  @ObservationIgnored var listFrame = CGRect.zero

  /// Set by the panel controller.
  @ObservationIgnored var onOpenSettings: () -> Void = {}
  @ObservationIgnored var onShowActions: () -> Void = {}
  @ObservationIgnored var onRequestClearHistory: () -> Void = {}

  @ObservationIgnored private var searchTask: Task<Void, Never>?
  /// A selection reset that a later search must not drop (a capture can cancel a keystroke's search).
  @ObservationIgnored private var pendingSelectionReset = false
  @ObservationIgnored private var detailTask: Task<Void, Never>?
  @ObservationIgnored private var imageTask: Task<Void, Never>?
  @ObservationIgnored private var thumbnailRequests: Set<Int64> = []

  init(controller: HistoryController) {
    self.controller = controller
  }

  var selectedRow: SearchHit? {
    rows.first { $0.id == selectedID }
  }

  var selectedIndex: Int? {
    rows.firstIndex { $0.id == selectedID }
  }

  // MARK: - Open and search

  func prepareForOpen(target: SourceApp?) {
    targetApp = target
    editorText = nil
    isCommandHeld = false
    controller.toast = nil
    if query.isEmpty && kindFilter == nil {
      search(resetSelection: true)
    } else {
      query = ""
      kindFilter = nil
    }
    openCount += 1
  }

  /// Runs the current query. Each call cancels the previous search.
  func search(resetSelection: Bool) {
    searchTask?.cancel()
    pendingSelectionReset = pendingSelectionReset || resetSelection
    let text = query
    let filter = kindFilter
    let store = controller.store
    isSearching = true
    searchTask = Task {
      let parsed = SearchQuery.parse(text, kind: filter)
      let response: SearchResponse
      do {
        if parsed.isEmpty {
          response = .hits(try await store.recent(limit: Self.rowLimit).map { SearchHit(summary: $0) })
        } else {
          response = try await store.search(parsed, limit: Self.rowLimit)
        }
      } catch is CancellationError {
        return
      } catch {
        Log.history.error("Search failed: \(String(describing: error), privacy: .public)")
        response = .hits([])
      }
      guard !Task.isCancelled else {
        return
      }
      apply(response)
    }
  }

  private func apply(_ response: SearchResponse) {
    isSearching = false
    let resetSelection = pendingSelectionReset
    pendingSelectionReset = false
    switch response {
    case .hits(let hits):
      searchError = nil
      rows = hits
    case .invalidRegex:
      searchError = "Invalid regular expression"
      rows = []
    }
    if resetSelection || selectedRow == nil {
      selectedID = rows.first?.id
    } else {
      // The row data can change (pin, copy count). Reload the preview.
      loadDetail()
    }
  }

  // MARK: - Selection

  func move(by offset: Int) {
    guard !rows.isEmpty else {
      return
    }
    let current = selectedIndex ?? -1
    let next = min(max(current + offset, 0), rows.count - 1)
    selectedID = rows[next].id
  }

  func moveToFirst() {
    selectedID = rows.first?.id
  }

  func moveToLast() {
    selectedID = rows.last?.id
  }

  /// The visible row at a point in the panel.
  func rowID(at point: CGPoint) -> Int64? {
    guard listFrame.contains(point),
          let id = rowFrames.first(where: { $0.value.contains(point) })?.key,
          rows.contains(where: { $0.id == id }) else {
      return nil
    }
    return id
  }

  /// Selects a row and waits for its detail, so `actions` lists all actions for it.
  func select(_ id: Int64) async {
    selectedID = id
    await detailTask?.value
  }

  /// Cycle mode wraps around at the end.
  func moveNextWrapping() {
    guard let index = selectedIndex, !rows.isEmpty else {
      moveToFirst()
      return
    }
    selectedID = rows[(index + 1) % rows.count].id
  }

  func cycleKindFilter() {
    let order: [ClipKind?] = [nil] + ClipKind.allCases.map { Optional($0) }
    let index = order.firstIndex { $0 == kindFilter } ?? 0
    kindFilter = order[(index + 1) % order.count]
  }

  // MARK: - Detail and images

  private func loadDetail() {
    detailTask?.cancel()
    imageTask?.cancel()
    guard let id = selectedID else {
      detail = nil
      previewImage = nil
      return
    }
    let store = controller.store
    if detail?.summary.id != id {
      previewImage = nil
    }
    detailTask = Task {
      let detail = try? await store.detail(id: id)
      guard !Task.isCancelled else {
        return
      }
      self.detail = detail
    }
    // A separate task: the actions menu waits for the detail, not for the image.
    guard selectedRow?.summary.kind == .image, previewImage == nil else {
      return
    }
    imageTask = Task {
      let image = await Self.loadPreviewImage(id: id, store: store)
      guard !Task.isCancelled else {
        return
      }
      previewImage = image
    }
  }

  @concurrent
  nonisolated private static func loadPreviewImage(id: Int64, store: HistoryStore) async -> NSImage? {
    guard let data = try? await store.imageData(id: id),
          let image = ImageProcessing.downsample(data, maxPixelSize: previewPixelSize) else {
      return nil
    }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }

  func thumbnail(for id: Int64) -> NSImage? {
    if let image = thumbnails[id] {
      return image
    }
    guard !thumbnailRequests.contains(id) else {
      return nil
    }
    thumbnailRequests.insert(id)
    let store = controller.store
    Task {
      if let data = try? await store.thumbnail(id: id), let image = NSImage(data: data) {
        if thumbnails.count > 500 {
          thumbnails.removeAll()
        }
        thumbnails[id] = image
      }
      thumbnailRequests.remove(id)
    }
    return nil
  }

  // MARK: - Actions

  /// Waits until the running search has applied its rows. Then ↩ never acts on
  /// the rows of an older query, even when the user types fast.
  private func settledSelection() async -> Int64? {
    while isSearching, let task = searchTask {
      await task.value
      if searchTask == task {
        // That search ended without results to apply (cancelled with no successor).
        break
      }
    }
    return selectedID
  }

  func performPrimary() {
    Task {
      guard let id = await settledSelection() else {
        // No result: copy the search text itself, like upstream Maccy.
        if !query.isEmpty {
          controller.deliver(text: query, as: .copy)
        }
        return
      }
      await controller.deliver(id, as: controller.primaryDelivery)
    }
  }

  func performSecondary() {
    Task {
      guard let id = await settledSelection() else {
        return
      }
      await controller.deliver(id, as: controller.secondaryDelivery)
    }
  }

  func pastePlainText() {
    Task {
      guard let id = await settledSelection() else {
        return
      }
      await controller.deliver(id, as: .paste, plainText: true)
    }
  }

  func performPrimary(atRow index: Int) {
    Task {
      _ = await settledSelection()
      guard rows.indices.contains(index) else {
        return
      }
      selectedID = rows[index].id
      await controller.deliver(rows[index].id, as: controller.primaryDelivery)
    }
  }

  func togglePin() {
    guard let row = selectedRow else {
      return
    }
    Task {
      await controller.setPinned(row.id, !row.summary.isPinned)
      search(resetSelection: false)
    }
  }

  func deleteSelected() {
    guard let index = selectedIndex else {
      return
    }
    let id = rows[index].id
    // Select the neighbor before the row goes away.
    let neighbor = rows.indices.contains(index + 1) ? rows[index + 1].id : (index > 0 ? rows[index - 1].id : nil)
    selectedID = neighbor
    Task {
      await controller.delete([id])
      search(resetSelection: false)
    }
  }

  func beginEditing() {
    guard let detail, detail.summary.kind != .image else {
      return
    }
    editorText = detail.text
  }

  func deliverEditedText(as delivery: HistoryController.Delivery) {
    guard let text = editorText else {
      return
    }
    editorText = nil
    controller.deliver(text: text, as: delivery)
  }

  /// Reloads after the history changed (new copy, prune), and keeps the selection.
  func historyDidChange() {
    search(resetSelection: false)
  }
}
