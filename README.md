# Pocketclip

<img src="docs/images/icon.png" width="128" height="128" alt="Pocketclip icon">

Pocketclip is a local macOS screenshot tool by Shawn Liu. Capture a region or a window, annotate it, then copy or save — all on your Mac, with no account and no network.

Hover a layout block and click to capture, or drag to select freely. After capture, a compact editor lets you mark up the image, pick colors, and browse recent shots.

![Pocketclip editor after a capture](docs/images/screenshot.png)

## Requirements

- macOS 14 Sonoma or later
- Screen Recording permission (Accessibility is optional and enables block snapping during region capture)
- Builds are self-signed and are not notarized. Gatekeeper may warn the first time you open the app; if macOS blocks it, right-click the app and choose Open.

## Shortcuts

- **Command-Shift-2** — Region capture. Hover a block and click to capture, or drag to free-select. Hold Option to select the parent block. Press Esc to cancel.
- **Command-Shift-3** — Capture a window (click the window you want).
- **Option-Shift-F** — Capture the full screen.

Recent captures are available from the menu bar (**Command-Shift-H**) or the editor (**Command-Y**).

The interface language follows macOS (English or Simplified Chinese).

## Build

From the project directory:

```
./build.sh
```

This compiles Pocketclip and installs it to `~/Applications/Pocketclip.app`.

Signing uses a local keychain identity so Screen Recording permission survives rebuilds. Set the `POCKETCLIP_SIGN_PASSWORD` environment variable to unlock that keychain, or run the script in a terminal and type the password at the hidden prompt. The password is not printed.

## License

MIT
