import AppKit
import MaccyCore
import Observation

/// Asks GitHub for the latest release of this fork and compares it with the running
/// version. It only tells the user: the user downloads the new version and replaces the app.
/// This is the only network request in Maccy. It sends nothing about the user or the history.
@Observable
final class UpdateChecker {
  nonisolated enum State: Sendable, Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String, page: URL)
    case failed(String)
  }

  nonisolated static let releasesPage = URL(string: "https://github.com/pgilad/Maccy/releases/latest")!
  nonisolated private static let latestRelease = URL(string: "https://api.github.com/repos/pgilad/Maccy/releases/latest")!
  // No cookies and no disk cache.
  nonisolated private static let session = URLSession(configuration: .ephemeral)
  /// Automatic checks run at most once a day.
  private static let interval: TimeInterval = 86_400

  private(set) var state = State.idle
  let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    .flatMap(AppVersion.init)
  @ObservationIgnored private let preferences: Preferences
  @ObservationIgnored private var schedule: Task<Void, Never>?

  init(preferences: Preferences) {
    self.preferences = preferences
  }

  /// Starts or stops the daily check.
  func setAutomatic(_ enabled: Bool) {
    schedule?.cancel()
    schedule = nil
    guard enabled else {
      return
    }
    // Look each hour, so a Mac that was asleep or off checks soon after a day has passed.
    schedule = Task { [weak self] in
      while !Task.isCancelled {
        await self?.checkIfDue()
        try? await Task.sleep(for: .seconds(3_600))
      }
    }
  }

  /// `showingResult`: show the result in an alert (Check for Updates… in a menu).
  /// Otherwise only `state` changes: Settings and the panel footer show it.
  func check(showingResult: Bool) async {
    guard state != .checking else {
      return
    }
    state = .checking
    state = await Self.fetchState(current: currentVersion)
    // Only a check that got an answer counts. After a failure (for example no network
    // just after login), the automatic check tries again at the next hourly look.
    switch state {
    case .upToDate, .available:
      preferences.lastUpdateCheck = .now
    case .idle, .checking, .failed:
      break
    }
    if showingResult {
      showResult()
    }
  }

  /// One line for Settings.
  var statusText: String {
    switch state {
    case .idle:
      preferences.lastUpdateCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))." }
        ?? "Not checked yet."
    case .checking: "Checking…"
    case .upToDate: "Maccy \(currentVersion?.description ?? "") is up to date."
    case .available(let version, _): "Maccy \(version) is available."
    case .failed(let message): message
    }
  }

  private func checkIfDue() async {
    if let last = preferences.lastUpdateCheck, Date.now.timeIntervalSince(last) < Self.interval {
      return
    }
    await check(showingResult: false)
  }

  @concurrent
  nonisolated static func fetchState(current: AppVersion?) async -> State {
    guard let current else {
      return .failed("This build has no version number.")
    }
    var request = URLRequest(url: latestRelease, timeoutInterval: 20)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    do {
      let (data, response) = try await session.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      switch status {
      case 200: break
      // Without a token, GitHub allows 60 requests an hour from one IP address.
      case 403, 429: return .failed("GitHub limits the number of checks. Try again in an hour.")
      case 404: return .failed("GitHub has no release of Maccy.")
      default: return .failed("GitHub returned HTTP \(status).")
      }
      let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
      guard let latest = release.version else {
        return .failed("The latest release has an unknown version: \(release.tagName).")
      }
      return latest > current ? .available(version: latest.description, page: release.pageURL ?? releasesPage) : .upToDate
    } catch {
      Log.app.error("Update check failed: \(error.localizedDescription, privacy: .public)")
      return .failed("Cannot reach GitHub: \(error.localizedDescription)")
    }
  }

  private func showResult() {
    let alert = NSAlert()
    let current = currentVersion?.description ?? "unknown"
    var page: URL?
    switch state {
    case .available(let version, let releasePage):
      page = releasePage
      alert.messageText = "Maccy \(version) is available"
      alert.informativeText = "You have Maccy \(current). Download the new version from GitHub, quit Maccy and replace the app."
      alert.addButton(withTitle: "Open Release Page")
      alert.addButton(withTitle: "Later")
    case .upToDate:
      alert.messageText = "Maccy is up to date"
      alert.informativeText = "Maccy \(current) is the latest version."
    case .failed(let message):
      alert.messageText = "Cannot check for updates"
      alert.informativeText = message
    case .idle, .checking:
      return
    }
    NSApp.activate()
    let response = alert.runModal()
    NSApp.returnFocusIfIdle()
    if let page, response == .alertFirstButtonReturn {
      NSWorkspace.shared.open(page)
    }
  }
}
