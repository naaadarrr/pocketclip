# Pocketclip

Pocketclip is a local macOS screenshot tool by Shawn Liu. Capture a region or a window, annotate it, then copy or save — all on your Mac, with no account and no network.

Hover a layout block and click to capture, or drag to select freely. After capture, a compact editor lets you mark up the image, pick colors, and browse recent shots.

![Pocketclip editor after a capture](docs/images/screenshot.png)

<p align="center">
  Free and open source. For macOS 14 and later.
  <br>
  <a href="https://github.com/naaadarrr/pocketclip/releases/latest">Download&nbsp;&rsaquo;</a>
  &nbsp;&nbsp;
  <a href="#build-from-source">Build from source&nbsp;&rsaquo;</a>
</p>

## Install

Download the latest release from [Releases](https://github.com/naaadarrr/pocketclip/releases/latest) — a disk image (or zip for older versions) — open it, and drag `Pocketclip.app` to Applications.

Builds are self-signed and are not notarized. The first time you open the app, macOS may warn or block it — right-click the app and choose **Open**, then confirm. After that, you can open it normally.

Screen Recording permission is required. Accessibility is optional and enables block snapping during region capture.

## Shortcuts

- **Command-Shift-2** — Region capture. Hover a block and click to capture, or drag to free-select. Hold Option to select the parent block. Press Esc to cancel.
- **Command-Shift-3** — Capture a window (click the window you want).
- **Option-Shift-F** — Capture the full screen.

Recent captures are available from the menu bar (**Command-Shift-H**) or the editor (**Command-Y**).

The interface language follows macOS (English or Simplified Chinese).

## Build from source

From the project directory:

```
./build.sh
```

This compiles Pocketclip and installs it to `~/Applications/Pocketclip.app`.

Signing uses a local keychain identity so Screen Recording permission survives rebuilds. Set the `POCKETCLIP_SIGN_PASSWORD` environment variable to unlock that keychain, or run the script in a terminal and type the password at the hidden prompt. The password is not printed.

To make a disk image for a release, run `./scripts/make-dmg.sh` after building.

## License

MIT
