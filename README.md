# Maccy (pgilad fork)

A fast, private clipboard manager for macOS 26 and later, built from source. It started as a fork of [p0deje/Maccy](https://github.com/p0deje/Maccy) and is now a rewrite with a Raycast-style panel, long history, full-text search, and no third-party code.

## Why this fork

- **Build from source, trust the source.** No third-party Swift packages, no auto-updater, no network access. The app links only Apple system frameworks. Updates are `git pull` and `make install`.
- **No Xcode needed.** It builds with the Command Line Tools (`xcode-select --install`).
- **Long history that stays fast.** SQLite with an FTS5 trigram index. Search over 100,000 items takes well under 100 ms in the worst case and under 1 ms for selective queries (`make perf`).

## Features

- Two-pane panel: results on the left, a full preview on the right (text, images, colors, links, files) with metadata: source app, size, dimensions, character/word/line count, copy times.
- Text, rich text, links, colors, images and files. Duplicates merge and move to the top.
- Search everywhere in the item, not only in the first line. Case- and diacritic-insensitive, ranked by match position, recency and frequency, with a fuzzy fallback.
- Text in images is searchable (on-device OCR with Vision).
- Type filter (⌘P) and search syntax: `type:image`, `app:slack`, `is:pinned`, `"exact phrase"`, `/regex/`.
- Actions menu (⌘K, a native macOS menu): paste, copy, paste as plain text, edit and paste, open link, show in Finder, save image, copy text in image, pin, delete.
- Pins stay at the top and are never deleted by retention.
- Retention by age (1 day to forever), item count, and total size.
- Pause capture from the menu bar (⌥-click, or right-click for timed pauses), or from a script: `defaults write com.pgilad.Maccy ignoreEvents true`.

## Privacy and security

- Copies that password managers mark as concealed or transient ([nspasteboard.org](http://nspasteboard.org)) are never read.
- Password managers are ignored by default (1Password, Apple Passwords, Keychain Access, Bitwarden, KeePassXC, Dashlane).
- Copies that look like credentials (AWS, GitHub, GitLab, Slack, Stripe, Google, OpenAI, Anthropic and npm tokens, JWTs, private keys) are deleted after 15 minutes by default, or not saved at all.
- The App Sandbox is on. The history lives in the app container, where macOS asks for consent before another app reads it. The data folder is excluded from Time Machine.
- SQLite runs with `secure_delete`, so deleted items are overwritten in the database file.
- No clipboard content in logs or notifications.

## Install

Requirements: macOS 26 or later on Apple silicon, and the Command Line Tools.

```fish
xcode-select --install          # once, if the tools are missing
git clone https://github.com/pgilad/Maccy.git
cd Maccy
make signing-identity           # once per Mac, asks for your login password
make install                    # builds, signs, copies to /Applications, starts
```

On first start, Maccy opens Settings. Grant **Accessibility** (needed to paste into other apps). If macOS asks about pasteboard access, choose to always allow Maccy.

`make signing-identity` creates a self-signed certificate, "Maccy Local Signing", in your login keychain. macOS ties the Accessibility permission to the code signature. Without a stable certificate, the build is signed ad-hoc, and you must grant Accessibility again after each rebuild.

To update:

```fish
git pull
make install
```

## Keyboard

| Key | Action |
| --- | --- |
| ⇧⌘C | Open the panel (change it in Settings) |
| Hold the modifiers, press C again | Select the next item; release to paste it |
| ↑ ↓, ⌃N ⌃P, ⌃J ⌃K | Move the selection |
| ↩ | Paste into the active app (or copy, see Settings) |
| ⌘↩ | Copy (or paste) |
| ⌥↩ | Paste as plain text |
| ⌘1 – ⌘9 | Paste one of the first nine items |
| ⌘K | Actions menu |
| ⌘, | Settings |
| ⌘P | Next type filter |
| ⇧⌘P | Pin or unpin |
| ⌘E | Edit, then paste |
| ⌘⌫ | Delete the item (when the search field is empty; while you search, use ⌘K › Delete) |
| ⇧⌘⌫ | Delete all unpinned items |
| ⎋ | Clear the search, then close |

If the shortcut does not work in password fields, see [docs/keyboard-shortcut-password-fields.md](docs/keyboard-shortcut-password-fields.md).

## Removed from upstream Maccy

- Sparkle auto-update, the appcast and App Store review prompts.
- Copy notifications and sounds (they put clipboard text into Notification Center).
- App Intents for Shortcuts: their metadata step needs Xcode, and this build does not.
- The 40 translations: the UI is English only.
- The paste stack, which upstream shipped turned off.
- All third-party Swift packages (Sparkle, Defaults, KeyboardShortcuts, Sauce, Settings, LaunchAtLogin, fuse-swift, SwiftHEXColors, swift-log, and swift-syntax through Defaults).

The new bundle ID is `com.pgilad.Maccy`, so this app does not share data or permissions with an installed upstream Maccy.

## Development

```fish
make build        # debug build
make test         # unit tests for MaccyCore (Swift Testing)
make self-test    # capture, store, search and paste-back on a private pasteboard
make snapshots    # render the panel to build/snapshots/*.png
make perf         # search timings on 100,000 generated items
make run          # run the debug build with a throwaway data folder
make app          # release build in build/Maccy.app
```

Layout:

- `Sources/MaccyCore`: storage (SQLite, FTS5, blob files), analysis (kind, title, hash, secrets, images), search and ranking, retention. No UI.
- `Sources/Maccy`: the app. Pasteboard monitor, paste, global shortcut (Carbon), panel and settings (SwiftUI), menu bar item.
- `Tests/MaccyCoreTests`: unit tests.
- `Resources`: Info.plist, entitlements, icons. `scripts/bundle.sh` assembles and signs the app.

`self-test` and `snapshots` exist only in debug builds. They never touch the real clipboard or your history.

## License

MIT. See [LICENSE](LICENSE).
