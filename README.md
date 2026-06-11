# D'Monte's Tool Box

A native macOS menu bar tool box — 20 fast, focused utilities in one lightweight Swift app, inspired by the convenience of Parallels Toolbox.

Open the tool box from the menu bar, search for what you need, and launch it. Each tool is a self-contained helper with its own polished SwiftUI interface; tools that run continuously (like System Monitor and Clipboard History) add their own menu bar item.

> **macOS 14+** · Universal · Signed with Developer ID and **notarized by Apple** — downloads open without Gatekeeper warnings.

## Download

Grab the latest signed, notarized build from the [**Releases**](https://github.com/havokentity/MacTools/releases/latest) page:

1. Download `DMonte-Tool-Box-<version>.zip`
2. Unzip and drag **DMonte Tool Box.app** to `/Applications`
3. Launch it — the tool box icon appears in your menu bar

The app updates itself automatically via [Sparkle](https://sparkle-project.org); new releases are delivered in the background with release notes shown from the GitHub release feed.

## The tools

| Tool | What it does |
| --- | --- |
| **System Monitor** | Live menu bar CPU, memory, disk, network, and temperature metrics |
| **Clipboard History** | Searchable clipboard with text/image/file capture, pinning, and quick‑paste (⇧⌘V) |
| **Clean Drive** | Reclaim space by clearing caches, logs, and temp files — async, with a live freeing‑up gauge |
| **Disk Usage Analyzer** | Interactive treemap of what's eating your disk |
| **Duplicate Finder** | Find and trash byte‑identical duplicate files |
| **Uninstall Apps** | Remove apps and their leftover support files |
| **Download Video** | Save videos from the web (bundled, checksum‑verified yt‑dlp) |
| **Image Converter** | Batch convert / resize / compress images (HEIC, JPEG, PNG, …) |
| **Grab Text** | OCR any region of the screen straight to your clipboard |
| **QR Studio** | Generate QR codes and scan them from the screen |
| **Color Picker** | System eyedropper with hex / RGB / HSL and a recent‑colors palette |
| **Window Manager** | Snap windows to halves, thirds, and corners with global shortcuts (⌃⌥ + arrows) |
| **Audio Switcher** | One‑click switching of the default input/output device |
| **Volume Mixer** | Per‑app volume sliders and per‑app output routing via CoreAudio process taps (macOS 14.2+) |
| **Audio Router** | Virtual audio routing — install independent loopback cables for app‑to‑app audio, build mirror/aggregate devices with presets, and "listen" to any input through an output |
| **Focus Timer** | Pomodoro timer with a live menu bar countdown |
| **Calendar** | Menu bar month view with your upcoming events |
| **Keep Awake** | Prevent sleep, optionally for a set duration |
| **Maintenance** | Handy Finder/system toggles and cache/index refreshes |
| **Dev Tools** | JSON, Base64, URL, hashing, UUID, timestamp, and case utilities |

### Permissions

A few tools ask macOS for access the first time you use them, and degrade gracefully if you decline:

- **Window Manager** — Accessibility (to move other apps' windows)
- **Clipboard History** — Accessibility (to paste into the active app)
- **Grab Text** / **QR Studio** (screen scan) — Screen Recording
- **Volume Mixer** — System Audio Recording (`NSAudioCaptureUsageDescription`, to tap each app's audio for per‑app volume and routing)
- **Calendar** — Calendar access
- **Audio Router** (listen to an input) — Microphone, and an admin prompt to install a loopback driver

Clipboard history is stored locally with owner‑only permissions and never records password‑manager or transient copies.

## Building from source

Requires macOS 14+ and a recent Swift toolchain (Xcode 26 / Swift 6.1).

```bash
swift build          # debug build
swift test           # run the test suite
swift run DMonte     # run the tool box from the menu bar
```

### Package a distributable app

```bash
Scripts/package_app.sh
open "dist/DMonte Tool Box.app"
```

`package_app.sh` builds in release mode, assembles the bundle with all helpers, and code‑signs it. With a Developer ID identity present it signs with the Hardened Runtime (notarization‑ready); otherwise it falls back to an ad‑hoc signature for local testing.

## Releasing

Releases are fully automated. Tagging `vX.Y.Z` triggers CI to build, hardened‑sign, **notarize and staple** with Apple, publish a GitHub Release, and update the Sparkle appcast.

```bash
Scripts/bump_version.sh 0.7.2
git commit -am "Release 0.7.2"
git tag v0.7.2
git push origin main v0.7.2
```

A `-rc` suffix (e.g. `v0.7.2-rc1`) publishes as a prerelease, so it's testable without reaching the auto‑update feed. Release notes are embedded into the Sparkle appcast from the GitHub release body when one already exists, falling back to the matching section in [`CHANGELOG.md`](CHANGELOG.md).

The auto‑update feed:

```text
https://github.com/havokentity/MacTools/releases/latest/download/appcast.xml
```

## Architecture

A single `DMonteCore` library holds each tool's pure, testable logic plus its SwiftUI views; the tool box and every tool are separate executables that share it. A data-driven `ToolboxCatalog` is the single source of truth for the dashboard, the launcher, and packaging — adding a tool is one catalog entry plus its helper target.

## License

GPL-3.0-only
