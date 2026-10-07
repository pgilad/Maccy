import AppKit

#if DEBUG
// Diagnostics for development builds: `Maccy --self-test`, `Maccy --render-snapshots <dir>`,
// `Maccy --check-update <version>`.
if Diagnostics.startIfRequested(CommandLine.arguments) {
  NSApplication.shared.setActivationPolicy(.prohibited)
  NSApplication.shared.run()
}
#endif

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// A menu bar app: no Dock icon and no app menu.
application.setActivationPolicy(.accessory)
application.run()
