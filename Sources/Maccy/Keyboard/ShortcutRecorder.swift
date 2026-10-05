import AppKit
import Carbon
import Combine
import SwiftUI

/// Records a global shortcut. Click, then type the shortcut. ⎋ cancels, ⌫ clears.
struct ShortcutRecorder: View {
  @Binding var combo: KeyCombo?

  @ViewState private var isRecording = false
  @ViewState private var monitor: Any?
  @ViewState private var message: String?
  /// The Settings window. The recorder handles keys only from this window.
  @ViewState private var window: NSWindow?

  var body: some View {
    HStack(spacing: 6) {
      Button {
        isRecording ? stop() : start()
      } label: {
        Text(label)
          .frame(minWidth: 120)
          .foregroundStyle(isRecording ? Color.accentColor : .primary)
      }
      if combo != nil && !isRecording {
        Button {
          combo = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .help("Remove shortcut")
      }
      if let message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .onDisappear(perform: stop)
    // Closing Settings only hides the window, so `onDisappear` may not run. Stop on resign key too.
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
      if isRecording, (notification.object as? NSWindow) === window {
        stop()
      }
    }
  }

  private var label: String {
    if isRecording {
      return "Type shortcut…"
    }
    return combo?.displayString ?? "Record Shortcut"
  }

  private func start() {
    message = nil
    window = NSApp.keyWindow
    isRecording = true
    HotKeyCenter.shared.suspend()
    let recordingWindow = window
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      // Leave typing in other windows (for example the panel) alone.
      guard event.window === recordingWindow else {
        return event
      }
      handle(event)
      return nil
    }
  }

  private func stop() {
    guard isRecording else {
      return
    }
    isRecording = false
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
    monitor = nil
    window = nil
    HotKeyCenter.shared.resume()
  }

  private func handle(_ event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
    if modifiers.isEmpty && Int(event.keyCode) == kVK_Escape {
      stop()
      return
    }
    if modifiers.isEmpty && (Int(event.keyCode) == kVK_Delete || Int(event.keyCode) == kVK_ForwardDelete) {
      combo = nil
      stop()
      return
    }
    let candidate = KeyCombo(keyCode: event.keyCode, modifiers: modifiers)
    guard candidate.isValidGlobalShortcut else {
      message = "Add ⌘, ⌥ or ⌃"
      NSSound.beep()
      return
    }
    combo = candidate
    stop()
  }
}
