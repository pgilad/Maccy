import AppKit
import MaccyCore
import Observation

enum RetentionOption: String, CaseIterable, Identifiable {
  case day, week, month, threeMonths, sixMonths, year, forever

  var id: Self { self }

  var title: String {
    switch self {
    case .day: "1 Day"
    case .week: "7 Days"
    case .month: "1 Month"
    case .threeMonths: "3 Months"
    case .sixMonths: "6 Months"
    case .year: "1 Year"
    case .forever: "Forever"
    }
  }

  var interval: TimeInterval? {
    let day: TimeInterval = 86_400
    switch self {
    case .day: return day
    case .week: return 7 * day
    case .month: return 30 * day
    case .threeMonths: return 91 * day
    case .sixMonths: return 182 * day
    case .year: return 365 * day
    case .forever: return nil
    }
  }
}

/// What happens to a copy that looks like a credential.
enum SecretPolicy: String, CaseIterable, Identifiable {
  case dontSave, oneMinute, fifteenMinutes, oneHour, oneDay, keep

  var id: Self { self }

  var title: String {
    switch self {
    case .dontSave: "Do Not Save"
    case .oneMinute: "Delete After 1 Minute"
    case .fifteenMinutes: "Delete After 15 Minutes"
    case .oneHour: "Delete After 1 Hour"
    case .oneDay: "Delete After 1 Day"
    case .keep: "Keep Like Other Items"
    }
  }

  var lifetime: TimeInterval? {
    switch self {
    case .dontSave: 0
    case .oneMinute: 60
    case .fifteenMinutes: 15 * 60
    case .oneHour: 3_600
    case .oneDay: 86_400
    case .keep: nil
    }
  }
}

enum PanelPosition: String, CaseIterable, Identifiable {
  case center, cursor, menuBarIcon, activeWindow, lastPosition

  var id: Self { self }

  var title: String {
    switch self {
    case .center: "Center of Screen"
    case .cursor: "Mouse Cursor"
    case .menuBarIcon: "Menu Bar Icon"
    case .activeWindow: "Center of Active Window"
    case .lastPosition: "Last Position"
    }
  }
}

enum MenuIcon: String, CaseIterable, Identifiable {
  case maccy, clipboard, scissors, paperclip

  var id: Self { self }

  /// The VoiceOver name in the icon picker. The status item has its own label.
  var title: String {
    switch self {
    case .maccy: "Maccy"
    case .clipboard: "Clipboard"
    case .scissors: "Scissors"
    case .paperclip: "Paper clip"
    }
  }

  var image: NSImage {
    let image: NSImage?
    switch self {
    case .maccy:
      image = Bundle.main.image(forResource: "StatusBarIcon")
        ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
    case .clipboard:
      image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)
    case .scissors:
      image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
    case .paperclip:
      image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
    }
    let result = image ?? NSImage()
    result.isTemplate = true
    result.accessibilityDescription = title
    return result
  }
}

/// All settings, stored in `UserDefaults`. SwiftUI binds to the properties directly.
@Observable
final class Preferences {
  nonisolated enum Key {
    static let hotKey = "hotKey"
    static let pasteAutomatically = "pasteAutomatically"
    static let pastePlainTextByDefault = "pastePlainTextByDefault"
    static let panelPosition = "panelPosition"
    static let retention = "retention"
    static let maxItems = "maxItems"
    static let maxStorageMB = "maxStorageMB"
    static let saveText = "saveText"
    static let saveImages = "saveImages"
    static let saveFiles = "saveFiles"
    static let maxImageMB = "maxImageMB"
    static let ignoredApps = "ignoredApps"
    static let onlyListedApps = "onlyListedApps"
    static let ignoredTypes = "ignoredTypes"
    static let ignorePatterns = "ignorePatterns"
    static let secretPolicy = "secretPolicy"
    static let ocrEnabled = "ocrEnabled"
    static let clearOnQuit = "clearOnQuit"
    static let clearSystemClipboard = "clearSystemClipboard"
    static let showAppIcons = "showAppIcons"
    static let showRecentCopyInMenuBar = "showRecentCopyInMenuBar"
    static let showInMenuBar = "showInMenuBar"
    static let menuIcon = "menuIcon"
    static let pollInterval = "pollInterval"
    static let windowWidth = "windowWidth"
    static let windowHeight = "windowHeight"
    static let windowAnchorX = "windowAnchorX"
    static let windowAnchorY = "windowAnchorY"
    static let didShowOnboarding = "didShowOnboarding"
    static let settingsTab = "settingsTab"
    // The names below match upstream Maccy, so `defaults write <bundle id> ignoreEvents true` still works.
    static let ignoreEvents = "ignoreEvents"
    static let ignoreOnlyNextEvent = "ignoreOnlyNextEvent"
    static let pauseUntil = "pauseUntil"
  }

  @ObservationIgnored private let defaults: UserDefaults

  var hotKey: KeyCombo? { didSet { store(hotKey, Key.hotKey) } }
  var pasteAutomatically: Bool { didSet { defaults.set(pasteAutomatically, forKey: Key.pasteAutomatically) } }
  var pastePlainTextByDefault: Bool { didSet { defaults.set(pastePlainTextByDefault, forKey: Key.pastePlainTextByDefault) } }
  var panelPosition: PanelPosition { didSet { defaults.set(panelPosition.rawValue, forKey: Key.panelPosition) } }

  var retention: RetentionOption { didSet { defaults.set(retention.rawValue, forKey: Key.retention) } }
  /// 0 means no limit.
  var maxItems: Int { didSet { defaults.set(maxItems, forKey: Key.maxItems) } }
  /// 0 means no limit.
  var maxStorageMB: Int { didSet { defaults.set(maxStorageMB, forKey: Key.maxStorageMB) } }
  var saveText: Bool { didSet { defaults.set(saveText, forKey: Key.saveText) } }
  var saveImages: Bool { didSet { defaults.set(saveImages, forKey: Key.saveImages) } }
  var saveFiles: Bool { didSet { defaults.set(saveFiles, forKey: Key.saveFiles) } }
  var maxImageMB: Int { didSet { defaults.set(maxImageMB, forKey: Key.maxImageMB) } }

  var ignoredApps: [String] { didSet { defaults.set(ignoredApps, forKey: Key.ignoredApps) } }
  var onlyListedApps: Bool { didSet { defaults.set(onlyListedApps, forKey: Key.onlyListedApps) } }
  var ignoredTypes: [String] { didSet { defaults.set(ignoredTypes, forKey: Key.ignoredTypes) } }
  var ignorePatterns: [String] { didSet { defaults.set(ignorePatterns, forKey: Key.ignorePatterns) } }
  var secretPolicy: SecretPolicy { didSet { defaults.set(secretPolicy.rawValue, forKey: Key.secretPolicy) } }
  var ocrEnabled: Bool { didSet { defaults.set(ocrEnabled, forKey: Key.ocrEnabled) } }
  var clearOnQuit: Bool { didSet { defaults.set(clearOnQuit, forKey: Key.clearOnQuit) } }
  var clearSystemClipboard: Bool { didSet { defaults.set(clearSystemClipboard, forKey: Key.clearSystemClipboard) } }

  var showAppIcons: Bool { didSet { defaults.set(showAppIcons, forKey: Key.showAppIcons) } }
  var showRecentCopyInMenuBar: Bool { didSet { defaults.set(showRecentCopyInMenuBar, forKey: Key.showRecentCopyInMenuBar) } }
  var showInMenuBar: Bool { didSet { defaults.set(showInMenuBar, forKey: Key.showInMenuBar) } }
  var menuIcon: MenuIcon { didSet { defaults.set(menuIcon.rawValue, forKey: Key.menuIcon) } }
  var pollInterval: Double { didSet { defaults.set(pollInterval, forKey: Key.pollInterval) } }

  var windowSize: CGSize {
    didSet {
      defaults.set(Double(windowSize.width), forKey: Key.windowWidth)
      defaults.set(Double(windowSize.height), forKey: Key.windowHeight)
    }
  }
  /// The top-center point of the panel, relative to the visible screen frame (0...1).
  var windowAnchor: CGPoint {
    didSet {
      defaults.set(Double(windowAnchor.x), forKey: Key.windowAnchorX)
      defaults.set(Double(windowAnchor.y), forKey: Key.windowAnchorY)
    }
  }
  var didShowOnboarding: Bool { didSet { defaults.set(didShowOnboarding, forKey: Key.didShowOnboarding) } }
  /// The last tab of the Settings window.
  var settingsTab: Int { didSet { defaults.set(settingsTab, forKey: Key.settingsTab) } }

  /// Capture is paused. Other processes can change this key, see `refreshPauseState()`.
  var ignoreEvents: Bool { didSet { defaults.set(ignoreEvents, forKey: Key.ignoreEvents) } }
  var ignoreOnlyNextEvent: Bool { didSet { defaults.set(ignoreOnlyNextEvent, forKey: Key.ignoreOnlyNextEvent) } }
  var pauseUntil: Date? { didSet { defaults.set(pauseUntil?.timeIntervalSince1970, forKey: Key.pauseUntil) } }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    defaults.register(defaults: [
      Key.pasteAutomatically: true,
      Key.pastePlainTextByDefault: false,
      Key.panelPosition: PanelPosition.center.rawValue,
      Key.retention: RetentionOption.threeMonths.rawValue,
      Key.maxItems: 0,
      Key.maxStorageMB: 2_048,
      Key.saveText: true,
      Key.saveImages: true,
      Key.saveFiles: true,
      Key.maxImageMB: 50,
      Key.ignoredApps: DefaultIgnoredApps.bundleIDs,
      Key.onlyListedApps: false,
      Key.ignoredTypes: Array(PasteboardTypes.defaultIgnored).sorted(),
      Key.ignorePatterns: [String](),
      Key.secretPolicy: SecretPolicy.fifteenMinutes.rawValue,
      Key.ocrEnabled: true,
      Key.clearOnQuit: false,
      Key.clearSystemClipboard: false,
      Key.showAppIcons: true,
      Key.showRecentCopyInMenuBar: false,
      Key.showInMenuBar: true,
      Key.menuIcon: MenuIcon.maccy.rawValue,
      Key.pollInterval: 0.25,
      Key.windowWidth: 780.0,
      Key.windowHeight: 500.0,
      Key.windowAnchorX: 0.5,
      Key.windowAnchorY: 0.75,
    ])

    hotKey = defaults.data(forKey: Key.hotKey).map { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
      ?? KeyCombo.defaultPopup
    pasteAutomatically = defaults.bool(forKey: Key.pasteAutomatically)
    pastePlainTextByDefault = defaults.bool(forKey: Key.pastePlainTextByDefault)
    panelPosition = PanelPosition(rawValue: defaults.string(forKey: Key.panelPosition) ?? "") ?? .center
    retention = RetentionOption(rawValue: defaults.string(forKey: Key.retention) ?? "") ?? .threeMonths
    maxItems = defaults.integer(forKey: Key.maxItems)
    maxStorageMB = defaults.integer(forKey: Key.maxStorageMB)
    saveText = defaults.bool(forKey: Key.saveText)
    saveImages = defaults.bool(forKey: Key.saveImages)
    saveFiles = defaults.bool(forKey: Key.saveFiles)
    maxImageMB = defaults.integer(forKey: Key.maxImageMB)
    ignoredApps = defaults.stringArray(forKey: Key.ignoredApps) ?? []
    onlyListedApps = defaults.bool(forKey: Key.onlyListedApps)
    ignoredTypes = defaults.stringArray(forKey: Key.ignoredTypes) ?? []
    ignorePatterns = defaults.stringArray(forKey: Key.ignorePatterns) ?? []
    secretPolicy = SecretPolicy(rawValue: defaults.string(forKey: Key.secretPolicy) ?? "") ?? .fifteenMinutes
    ocrEnabled = defaults.bool(forKey: Key.ocrEnabled)
    clearOnQuit = defaults.bool(forKey: Key.clearOnQuit)
    clearSystemClipboard = defaults.bool(forKey: Key.clearSystemClipboard)
    showAppIcons = defaults.bool(forKey: Key.showAppIcons)
    showRecentCopyInMenuBar = defaults.bool(forKey: Key.showRecentCopyInMenuBar)
    showInMenuBar = defaults.bool(forKey: Key.showInMenuBar)
    menuIcon = MenuIcon(rawValue: defaults.string(forKey: Key.menuIcon) ?? "") ?? .maccy
    pollInterval = min(2, max(0.1, defaults.double(forKey: Key.pollInterval)))
    windowSize = CGSize(width: defaults.double(forKey: Key.windowWidth), height: defaults.double(forKey: Key.windowHeight))
    windowAnchor = CGPoint(x: defaults.double(forKey: Key.windowAnchorX), y: defaults.double(forKey: Key.windowAnchorY))
    didShowOnboarding = defaults.bool(forKey: Key.didShowOnboarding)
    settingsTab = defaults.integer(forKey: Key.settingsTab)
    ignoreEvents = defaults.bool(forKey: Key.ignoreEvents)
    ignoreOnlyNextEvent = defaults.bool(forKey: Key.ignoreOnlyNextEvent)
    let pauseTimestamp = defaults.double(forKey: Key.pauseUntil)
    pauseUntil = pauseTimestamp > 0 ? Date(timeIntervalSince1970: pauseTimestamp) : nil
  }

  var isPaused: Bool {
    ignoreEvents || (pauseUntil.map { $0 > .now } ?? false)
  }

  // All pause and resume paths use these methods. Each one sets all three keys, so a
  // "skip next copy" flag that is left over cannot turn a later pause into one skip.
  // The capture queue reads the keys at any time, so the order of the writes matters.

  /// Pauses capture until `resume()`, or until `date`.
  func pause(until date: Date? = nil) {
    ignoreOnlyNextEvent = false
    if let date {
      ignoreEvents = false
      pauseUntil = date
    } else {
      pauseUntil = nil
      ignoreEvents = true
    }
  }

  /// Skips the next copy only. The capture queue clears both keys at that copy.
  func skipNextCopy() {
    pauseUntil = nil
    ignoreOnlyNextEvent = true
    ignoreEvents = true
  }

  func resume() {
    ignoreEvents = false
    ignoreOnlyNextEvent = false
    pauseUntil = nil
  }

  func togglePause() {
    refreshPauseState()
    if isPaused {
      resume()
    } else {
      pause()
    }
  }

  /// Reads the pause keys again. A shell script or the capture queue can change them.
  func refreshPauseState() {
    let events = defaults.bool(forKey: Key.ignoreEvents)
    if events != ignoreEvents { ignoreEvents = events }
    let onlyNext = defaults.bool(forKey: Key.ignoreOnlyNextEvent)
    if onlyNext != ignoreOnlyNextEvent { ignoreOnlyNextEvent = onlyNext }
    if let pauseUntil, pauseUntil <= .now { self.pauseUntil = nil }
  }

  var retentionPolicy: RetentionPolicy {
    RetentionPolicy(
      maxAge: retention.interval,
      maxItems: maxItems > 0 ? maxItems : nil,
      maxTotalBytes: maxStorageMB > 0 ? maxStorageMB * 1_048_576 : nil
    )
  }

  private func store<T: Encodable>(_ value: T?, _ key: String) {
    if let value, let data = try? JSONEncoder().encode(value) {
      defaults.set(data, forKey: key)
    } else {
      // An empty value means "no shortcut". A missing key means "use the default".
      defaults.set(Data(), forKey: key)
    }
  }
}
