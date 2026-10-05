import SwiftUI

private struct SnapshotKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  /// `true` while `--render-snapshots` renders views offscreen. ImageRenderer cannot
  /// draw AppKit-backed views (scroll views, text fields, menus), so views use plain
  /// SwiftUI stand-ins in this mode. (The `@Entry` macro needs Xcode, so no macro here.)
  var isSnapshot: Bool {
    get { self[SnapshotKey.self] }
    set { self[SnapshotKey.self] = newValue }
  }
}

/// A vertical scroll view, or a plain clipped stack in snapshot mode.
struct VerticalScroll<Content: View>: View {
  @Environment(\.isSnapshot) private var isSnapshot
  @ViewBuilder let content: () -> Content

  var body: some View {
    if isSnapshot {
      VStack(alignment: .leading, spacing: 0) {
        content()
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .clipped()
    } else {
      ScrollView {
        content()
      }
    }
  }
}

func pluralized(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
  "\(count.formatted()) \(count == 1 ? singular : (plural ?? singular + "s"))"
}
