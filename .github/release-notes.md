## Install

Requires macOS 26 or later on Apple silicon.

1. Download `Maccy-__VERSION__-arm64.zip` below. Open it and move **Maccy** to **Applications**.
2. Open Maccy. macOS blocks the first start, because the app is not notarized. Go to **System Settings → Privacy & Security** and click **Open Anyway**.
3. Grant **Accessibility** so Maccy can paste into other apps. On macOS 27, this permission has the name **Device Control and Data Access**.

To update, quit Maccy and replace the app. If macOS blocks the new version, do step 2 again. Maccy checks GitHub once a day and tells you when a new release is out. To turn this off, go to **Settings → About**.

This release uses the shared `Gilad Peleg Local Signing` certificate used by local builds. Keep the same app in Applications when you update.

## Verify the download

```fish
shasum -a 256 -c Maccy-__VERSION__-arm64.zip.sha256
gh attestation verify Maccy-__VERSION__-arm64.zip --repo pgilad/Maccy
```
