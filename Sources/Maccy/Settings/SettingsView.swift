import Combine
import MaccyCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General

struct GeneralSettings: View {
  @Bindable var preferences: Preferences
  @ViewState private var launchAtLogin = LaunchAtLogin.isEnabled
  @ViewState private var loginItemNeedsApproval = LaunchAtLogin.needsApproval
  @ViewState private var accessibility = Permissions.accessibilityGranted
  @ViewState private var pasteboardAccess = Permissions.pasteboardAccessDescription

  var body: some View {
    Form {
      Section("Permissions") {
        PermissionRow(
          title: "Accessibility",
          detail: "Needed to paste into other apps. Without it, Maccy copies, and you press ⌘V.",
          isGranted: accessibility,
          status: accessibility ? "Allowed" : "Not allowed",
          action: {
            Paster.requestAccess()
            Permissions.openAccessibilitySettings()
          }
        )
        PermissionRow(
          title: "Pasteboard access",
          detail: "Set Maccy to always allow pasteboard access in Privacy & Security, if macOS asks.",
          isGranted: !Permissions.pasteboardAccessNeedsAttention,
          status: pasteboardAccess,
          action: Permissions.openPrivacySettings
        )
      }

      Section("Startup") {
        Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { enabled in
          LaunchAtLogin.set(enabled)
          refreshStatus()
        }))
        if loginItemNeedsApproval {
          HStack {
            Text("Approve Maccy in System Settings › General › Login Items.")
              .font(.caption)
              .foregroundStyle(.orange)
            Spacer()
            Button("Open Login Items") {
              SMAppService.openSystemSettingsLoginItems()
            }
            .controlSize(.small)
          }
        }
      }

      Section("Panel") {
        LabeledContent("Open shortcut") {
          ShortcutRecorder(combo: $preferences.hotKey)
        }
        Picker("Position", selection: $preferences.panelPosition) {
          ForEach(PanelPosition.allCases) { Text($0.title).tag($0) }
        }
        Toggle("Show app icons", isOn: $preferences.showAppIcons)
      }

      Section {
        Toggle("Paste automatically", isOn: $preferences.pasteAutomatically)
        Toggle("Paste as plain text by default", isOn: $preferences.pastePlainTextByDefault)
      } header: {
        Text("Return key")
      } footer: {
        Text(returnKeyDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Menu bar") {
        Toggle("Show icon in menu bar", isOn: $preferences.showInMenuBar)
        Picker("Icon", selection: $preferences.menuIcon) {
          ForEach(MenuIcon.allCases) { icon in
            Image(nsImage: icon.image).tag(icon)
          }
        }
        .pickerStyle(.segmented)
        Toggle("Show the latest copy next to the icon", isOn: $preferences.showRecentCopyInMenuBar)
      }
    }
    .formStyle(.grouped)
    // The user changes these in System Settings, then comes back to Maccy.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshStatus()
    }
  }

  private func refreshStatus() {
    accessibility = Permissions.accessibilityGranted
    pasteboardAccess = Permissions.pasteboardAccessDescription
    launchAtLogin = LaunchAtLogin.isEnabled
    loginItemNeedsApproval = LaunchAtLogin.needsApproval
  }

  private var returnKeyDescription: String {
    let primary = preferences.pasteAutomatically ? "pastes into the active app" : "copies to the clipboard"
    let secondary = preferences.pasteAutomatically ? "copies" : "pastes"
    return "↩ \(primary). ⌘↩ \(secondary). ⌥↩ pastes as plain text. ⌘1–⌘9 paste the first nine items."
  }
}

struct PermissionRow: View {
  let title: String
  let detail: String
  let isGranted: Bool
  let status: String
  let action: () -> Void

  var body: some View {
    HStack(alignment: .top) {
      Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .foregroundStyle(isGranted ? .green : .orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 4) {
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
        if !isGranted {
          Button("Open Settings", action: action)
            .controlSize(.small)
        }
      }
    }
  }
}

// MARK: - History

struct HistorySettings: View {
  @Bindable var preferences: Preferences
  let controller: HistoryController
  @ViewState private var stats: HistoryStats?
  @ViewState private var confirmClear = false
  @ViewState private var confirmClearAll = false

  var body: some View {
    Form {
      Section("Keep") {
        Picker("Keep history for", selection: $preferences.retention) {
          ForEach(RetentionOption.allCases) { Text($0.title).tag($0) }
        }
        LimitPicker(
          title: "Maximum items",
          selection: $preferences.maxItems,
          presets: [1_000, 5_000, 10_000, 50_000, 100_000],
          label: { "\($0.formatted()) items" }
        )
        LimitPicker(
          title: "Maximum storage",
          selection: $preferences.maxStorageMB,
          presets: [256, 512, 1_024, 2_048, 5_120, 10_240],
          label: Self.megabytes
        )
        Text("When a limit is reached, the oldest items are deleted first. Pinned items are never deleted.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .onChange(of: preferences.retentionPolicy) {
        Task {
          await controller.prune()
          await refreshStats()
        }
      }

      Section("Save") {
        Toggle("Text, rich text and links", isOn: $preferences.saveText)
        Toggle("Images", isOn: $preferences.saveImages)
        Toggle("Files", isOn: $preferences.saveFiles)
        Picker("Largest image", selection: $preferences.maxImageMB) {
          ForEach(Self.imageSizes(including: preferences.maxImageMB), id: \.self) { size in
            Text(Self.megabytes(size)).tag(size)
          }
        }
        Toggle("Find text in images (on-device OCR)", isOn: $preferences.ocrEnabled)
      }

      Section("Storage") {
        if let stats {
          LabeledContent("Items", value: "\(stats.itemCount.formatted()) (\(stats.pinnedCount) pinned)")
          LabeledContent("Disk use", value: ByteCountFormatter.string(fromByteCount: Int64(stats.diskBytes), countStyle: .file))
        }
        Toggle("Clear history on quit", isOn: $preferences.clearOnQuit)
        Toggle("Also clear the system clipboard", isOn: $preferences.clearSystemClipboard)
        HStack {
          Button("Clear Unpinned…") { confirmClear = true }
          Button("Clear All…", role: .destructive) { confirmClearAll = true }
          Spacer()
          Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([controller.store.directory])
          }
        }
      }
    }
    .formStyle(.grouped)
    .task { await refreshStats() }
    .onChange(of: controller.revision) {
      Task { await refreshStats() }
    }
    .confirmationDialog("Delete all unpinned items?", isPresented: $confirmClear) {
      Button("Delete", role: .destructive) {
        Task {
          await controller.clearHistory(keepPinned: true)
          await refreshStats()
        }
      }
    } message: {
      Text("You cannot undo this.")
    }
    .confirmationDialog("Delete all items, pinned items too?", isPresented: $confirmClearAll) {
      Button("Delete All", role: .destructive) {
        Task {
          await controller.clearHistory(keepPinned: false)
          await refreshStats()
        }
      }
    } message: {
      Text("You cannot undo this.")
    }
  }

  private func refreshStats() async {
    stats = try? await controller.store.stats()
  }

  static func megabytes(_ value: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value) * 1_048_576, countStyle: .memory)
  }

  static func imageSizes(including current: Int) -> [Int] {
    Array(Set([10, 25, 50, 100, 200, current].filter { $0 > 0 })).sorted()
  }
}

/// A menu of preset limits plus "Unlimited" (stored as 0). A value set outside
/// the presets (for example with `defaults write`) is kept and shown.
struct LimitPicker: View {
  let title: String
  @Binding var selection: Int
  let presets: [Int]
  let label: (Int) -> String

  var body: some View {
    Picker(title, selection: $selection) {
      Text("Unlimited").tag(0)
      Divider()
      ForEach(values, id: \.self) { value in
        Text(label(value)).tag(value)
      }
    }
  }

  private var values: [Int] {
    Array(Set(presets + (selection > 0 ? [selection] : []))).sorted()
  }
}

// MARK: - Privacy

struct PrivacySettings: View {
  @Bindable var preferences: Preferences
  @ViewState private var newType = ""
  @ViewState private var newPattern = ""

  var body: some View {
    Form {
      Section {
        Picker("Copies that look like secrets", selection: $preferences.secretPolicy) {
          ForEach(SecretPolicy.allCases) { Text($0.title).tag($0) }
        }
      } footer: {
        Text(
          "Detects API keys and tokens (AWS, GitHub, GitLab, Slack, Stripe, Google, OpenAI, Anthropic, npm, Azure), "
            + "JSON Web Tokens and private keys (including PGP). Copies that password managers mark as concealed are never saved."
        )
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Save copies only from the apps in the list", isOn: $preferences.onlyListedApps)
        ForEach(preferences.ignoredApps, id: \.self) { bundleID in
          HStack {
            if let icon = AppIcons.icon(for: bundleID) {
              Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            if let name = AppIcons.name(for: bundleID) ?? Self.knownAppNames[bundleID] {
              Text(name)
              Text(bundleID)
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              Text(bundleID)
            }
            Spacer()
            RemoveButton { preferences.ignoredApps.removeAll { $0 == bundleID } }
          }
        }
        Button("Add App…", action: addApp)
      } header: {
        Text(preferences.onlyListedApps ? "Allowed apps" : "Ignored apps")
      }

      Section {
        ForEach(preferences.ignoredTypes, id: \.self) { type in
          HStack {
            Text(type).font(.callout.monospaced())
            Spacer()
            RemoveButton { preferences.ignoredTypes.removeAll { $0 == type } }
          }
        }
        HStack {
          TextField("Pasteboard type", text: $newType, prompt: Text("com.example.secret-type"))
            .labelsHidden()
          Button("Add") {
            let value = newType.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty && !preferences.ignoredTypes.contains(value) {
              preferences.ignoredTypes.append(value)
            }
            newType = ""
          }
        }
      } header: {
        Text("Ignored pasteboard types")
      }

      Section {
        let invalid = Set(IgnorePatterns(preferences.ignorePatterns).invalidPatterns)
        ForEach(preferences.ignorePatterns, id: \.self) { pattern in
          HStack {
            Text(pattern).font(.callout.monospaced())
            if invalid.contains(pattern) {
              Text("Invalid").font(.caption).foregroundStyle(.red)
            }
            Spacer()
            RemoveButton { preferences.ignorePatterns.removeAll { $0 == pattern } }
          }
        }
        HStack {
          TextField("Regular expression", text: $newPattern, prompt: Text("Regular expression, for example ^\\d{6}$"))
            .labelsHidden()
          Button("Add") {
            let value = newPattern.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty && !preferences.ignorePatterns.contains(value) {
              preferences.ignorePatterns.append(value)
            }
            newPattern = ""
          }
        }
      } header: {
        Text("Ignore copies that match")
      } footer: {
        Text("Maccy does not save a copy when the patterns cannot check it in 0.25 seconds, for example a slow pattern on a large copy.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  /// Names for the default ignored apps, for Macs where they are not installed.
  static let knownAppNames: [String: String] = [
    "com.1password.1password": "1Password",
    "com.agilebits.onepassword7": "1Password 7",
    "com.apple.Passwords": "Passwords",
    "com.apple.keychainaccess": "Keychain Access",
    "com.bitwarden.desktop": "Bitwarden",
    "org.keepassxc.keepassxc": "KeePassXC",
    "com.dashlane.dashlanephonefinal": "Dashlane",
  ]

  private func addApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(filePath: "/Applications")
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else {
      return
    }
    for url in panel.urls {
      if let bundleID = Bundle(url: url)?.bundleIdentifier, !preferences.ignoredApps.contains(bundleID) {
        preferences.ignoredApps.append(bundleID)
      }
    }
  }
}

struct RemoveButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "minus.circle.fill")
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.borderless)
    .help("Remove")
  }
}

// MARK: - Advanced

struct AdvancedSettings: View {
  @Bindable var preferences: Preferences

  var body: some View {
    Form {
      Section {
        Toggle("Pause capture", isOn: $preferences.ignoreEvents)
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Text("⌥-click the menu bar icon to pause or resume. ⇧⌥-click skips only the next copy. A script can do the same:")
          Text("defaults write \(Bundle.main.bundleIdentifier ?? "com.pgilad.Maccy") ignoreEvents true")
            .font(.caption.monospaced())
            .textSelection(.enabled)
          Text("defaults write \(Bundle.main.bundleIdentifier ?? "com.pgilad.Maccy") ignoreOnlyNextEvent true")
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        Picker("Check the clipboard every", selection: $preferences.pollInterval) {
          Text("0.1 s").tag(0.1)
          Text("0.25 s").tag(0.25)
          Text("0.5 s").tag(0.5)
          Text("1 s").tag(1.0)
        }
      } footer: {
        Text("macOS has no clipboard change event. Maccy compares a change counter, which reads no content.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}
