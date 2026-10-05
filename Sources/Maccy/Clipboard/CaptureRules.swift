import Foundation
import MaccyCore

/// A thread-safe copy of the settings that the capture queue needs.
nonisolated struct CaptureRules: Sendable {
  var saveText = true
  var saveImages = true
  var saveFiles = true
  var maxImageBytes = 50 * 1_048_576
  var maxTextBytes = 20 * 1_048_576
  var ignoredTypes: Set<String> = PasteboardTypes.alwaysIgnored.union(PasteboardTypes.defaultIgnored)
  var ignoredApps: Set<String> = Set(DefaultIgnoredApps.bundleIDs)
  var onlyListedApps = false
  var ignorePatterns = IgnorePatterns([])
  /// `nil` keeps detected secrets. Zero means "do not save".
  var secretLifetime: TimeInterval? = 15 * 60
  var ocrEnabled = true

  @MainActor
  init(preferences: Preferences) {
    secretLifetime = preferences.secretPolicy.lifetime
    ocrEnabled = preferences.ocrEnabled
    saveText = preferences.saveText
    saveImages = preferences.saveImages
    saveFiles = preferences.saveFiles
    maxImageBytes = max(1, preferences.maxImageMB) * 1_048_576
    ignoredTypes = PasteboardTypes.alwaysIgnored.union(preferences.ignoredTypes)
    ignoredApps = Set(preferences.ignoredApps)
    onlyListedApps = preferences.onlyListedApps
    ignorePatterns = IgnorePatterns(preferences.ignorePatterns)
  }

  init() {}

  func isIgnored(bundleID: String?) -> Bool {
    guard let bundleID else {
      return onlyListedApps
    }
    return onlyListedApps ? !ignoredApps.contains(bundleID) : ignoredApps.contains(bundleID)
  }

  /// The pasteboard types to read from one pasteboard item, in the order to keep.
  func typesToRead(from available: [String]) -> [String] {
    var result: [String] = []
    if saveText {
      result += PasteboardTypes.text.filter(available.contains)
    }
    if saveFiles {
      result += PasteboardTypes.files.filter(available.contains)
    }
    // Read only the best image type. The others hold the same picture.
    if saveImages, let image = PasteboardTypes.images.first(where: available.contains) {
      result.append(image)
    }
    return result
  }

  func sizeLimit(for type: String) -> Int {
    PasteboardTypes.images.contains(type) ? maxImageBytes : maxTextBytes
  }
}
