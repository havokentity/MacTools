# Changelog

All notable changes to D'Monte's Tool Box are documented here. This project
adheres to [Semantic Versioning](https://semver.org) and the
[Keep a Changelog](https://keepachangelog.com) format.

## [Unreleased]

### Added
- **Audio Switcher** now saves device profiles: name the input/output pair you
  are on — "Headset", "Desk", "Meeting" — and switch back to it with one click.
  Profiles remember devices by their CoreAudio UID rather than the numeric
  device id the system recycles across reboots and re-plugs, so a profile keeps
  pointing at the headset you saved and never at whatever inherited its number.
  A profile whose device is unplugged is shown greyed out with the reason
  (Output “Bose QC 35” isn’t connected) and cannot be applied at all, rather
  than half-applying and leaving you on a setup you did not ask for. Profiles
  can be renamed and deleted in the popover.

## [0.14.0] — 2026-07-21

### Added
- **Mic Control**, a new tool: mutes and unmutes the default input device
  system‑wide, so every app listening to it goes quiet at once. The menu bar
  icon is the point — a slashed mic when you're muted, a filled one when you're
  live — and CoreAudio property listeners keep it truthful when something else
  (a meeting app, Control Center, unplugging the mic) changes the state behind
  its back. Shows the device's input level as a slider where the hardware
  offers one, and says so plainly when a device exposes no mute control instead
  of offering a button that does nothing. Setting a device's mute switch is not
  audio capture, so it needs no microphone permission.
- **Snippets**, a new menu bar tool: a searchable library of reusable text.
  Click a snippet (or press ⏎ on the top search hit) to copy it and paste it
  straight into the app you were working in, the way Clipboard History does.
  Snippets are created, edited, reordered and deleted in the popover and stored
  locally with owner-only permissions. Each one can opt into date/time
  placeholders — `{date}`, `{time}` and `{datetime}` are replaced as it pastes;
  anything else in braces is left alone. Pasting needs Accessibility access;
  without it the snippet is still copied and the popover says so.
- Continuous integration: every push and pull request now builds the package
  and runs the full test suite on a pinned macOS runner, using the same
  toolchain the release workflow ships with. Previously only version tags ran
  CI, so a branch could go unverified until release day.
- **Dev Tools** JWT decoder: paste a token to see its header and payload as
  pretty-printed JSON, with `iat`/`nbf`/`exp` rendered as UTC dates plus a
  relative hint and a live/expired badge. The signature is shown verbatim and
  explicitly marked as unverified.
- **Drive Ejector**: a new menu bar tool that lists mounted external volumes
  with their capacity and free space and ejects them individually or all at
  once. Only removable, non-internal volumes are ever listed, and every volume
  is re-checked against the mount table the moment before it is ejected, so the
  startup disk and internal drives cannot be unmounted even if a listed row goes
  stale. Nothing is ever force-unmounted: when a file is open or Spotlight is
  still indexing, the disk stays mounted and macOS's own reason is shown inline.
  The list updates live as disks are plugged in and removed.
- **Scratchpad** — a new menu bar tool: an always-there plain-text notepad with
  multiple named notes, autosave (debounced while typing, flushed when the panel
  closes and at quit, one atomically written file per note), a live
  word/character/line count, copy-all, and an undoable clear.
- **Network Info**: a new menu bar tool showing the active interface and its
  type, local IPv4, subnet mask, router, IPv6, and the configured DNS servers,
  with every value click‑to‑copy. Local details are read from `getifaddrs` and
  SystemConfiguration and never leave the Mac; the view refreshes itself when
  the network changes rather than only at launch. The public‑IP lookup is a
  separate, explicitly user‑initiated button that names the service it queries
  (`api.ipify.org`) and can optionally be set to run automatically — it is
  never fetched silently at launch, because that would disclose your address to
  a third party every time the tool opens. No speed test: a throughput test
  means sustained multi‑megabyte transfers from someone else's server, which is
  its own decision about data usage and which server to trust, and does not
  belong in a read‑only local‑info tool.
- **Download Video** audio-only mode: pull just the soundtrack as M4A or MP3
  instead of the full video.
- **Clipboard History** now extracts text from image entries with OCR, so a
  screenshot of a code block or an address becomes selectable text.
- **QR Studio** content templates (Wi‑Fi, contact, email, phone, SMS,
  geolocation) that build correctly-formatted payloads instead of leaving you to
  remember each scheme, plus decoding a QR code from an image file.
- **Calendar** per-calendar filtering, so a noisy shared calendar can be hidden
  without unsubscribing, and clicking a day opens that date in Calendar.app.
  Event dots are coloured per calendar rather than all one colour.
- Text-entry tools now install an Edit menu, so ⌘C/⌘V/⌘X/⌘A/⌘Z work in every
  helper. Menu-bar helpers are accessory apps with no main menu, so the standard
  editing shortcuts previously did nothing in their text fields.
- Releases are now gated on the test suite, the runner is pinned to the image
  that can actually build the package, and concurrent release runs are
  serialised so two tags cannot race and publish mismatched artifacts.

### Fixed
- A deep review of the codebase fixed 62 confirmed bugs across the tools,
  raising the test suite from 360 to 772 tests.
- Settings sheets no longer overflow their panel. The sheet's size was a
  literal while the panel's scaled with the menu bar, so on a Mac with a thinner
  menu bar the sheet spilled past both edges and dragged the content behind it
  off-screen. Affected Keep Awake, Focus Timer, Mic Control, Drive Ejector,
  Network Info and Scratchpad.
- **Volume Mixer**: ignoring an app now releases its audio tap instead of only
  hiding its row; "stop processing" survives a relaunch; and quitting no longer
  persists a stop for every app that merely happened to be playing, which
  brought them all back permanently force-off with the slider reading one level
  while the audio played at another.
- **Audio Switcher**: the volume slider no longer stutters mid-drag, and
  dismissing the popover mid-drag no longer freezes volume sync for the rest of
  the session.
- **Audio Router** and **Calendar** now carry their entitlements on the
  container app. macOS attributes a nested helper's permission request to the
  containing bundle, so without them the microphone and calendar prompts could
  never be granted.
- **Drive Ejector** lists external SSDs that report themselves as neither
  removable nor ejectable, which is most of them.
- **Download Video** treats a different output format as a new download rather
  than a duplicate, so re-fetching a link as MP3 after M4A works.
- **Snippets** reorder shortcut moved to ⌥⌘↑/⌥⌘↓, clearing a collision with
  Mission Control.

## [0.13.0] — 2026-07-12

### Added
- **Keep Awake** "Turn Off Displays" button: puts the screens to sleep
  immediately while the Mac — and any running Keep Awake session — stays
  awake. Any key press or mouse move lights them back up.

## [0.12.0] — 2026-07-10

### Changed
- **Keep Awake** duration buttons toggle: pressing the running preset again
  turns Keep Awake off.

### Fixed
- **Keep Awake** duration buttons now highlight only the preset that started
  the session; previously every timed button lit up while any countdown was
  running.
- Audio Router "listen to an input" no longer crashes (macOS TCC): the
  microphone usage string now also ships in the main app's Info.plist, since
  macOS attributes a nested helper's privacy access to the containing app; and a
  build without any usage string (e.g. `swift run`) declines with a message
  instead of aborting.

## [0.11.0] — 2026-07-06

### Added
- **Window Manager** corner chords: tap two perpendicular half-snap shortcuts in
  quick succession — e.g. Right Half then Top Half — to snap the window to that
  corner (⌃⌥→ then ⌃⌥↑ = top-right) instead of firing two halves. The popover
  shows a tip explaining it.

### Fixed
- **Window Manager** shortcut recording now releases the global snap hotkeys
  while capturing, so you can assign a combination the tool already claims (e.g.
  ⌃⌥→) — previously Carbon intercepted it and the recorder never saw the keys.
- **Window Manager** no longer snaps the wrong window on multi-monitor setups.
  When opening the popover re-activates the app you were already in (it owns the
  top window on the popover's display too), the target resolver now keeps that
  window instead of jumping past it to an older, unrelated app, and peels the
  entire trailing run of the opening click's own display-switch activations.
- **Keep Awake** only reports itself active when the power assertion was actually
  taken, and won't start a countdown if the assertion failed to create.
- **Video Downloader** shows the recent-downloads list newest first.

## [0.10.0] — 2026-06-24

### Fixed
- **Video Downloader** now reliably downloads YouTube Shorts, X (Twitter), and
  Instagram videos. Several root causes were addressed:
  - Bundled **ffmpeg/ffprobe** so videos delivered as separate audio/video
    streams (Shorts, X, Instagram, most modern YouTube) merge correctly. The tool
    no longer relies on a system/Homebrew ffmpeg, which a Finder-launched app
    cannot find on its minimal `PATH`.
  - Bundled the **Deno** runtime so yt-dlp can solve YouTube's JavaScript
    "n‑challenge" — required whenever browser cookies are used, and increasingly
    required in general. Without it, downloads failed with "Requested format is
    not available".
  - Subtitles now default to **English + your system language** rather than every
    available language, which had started tripping YouTube's rate limiting
    (HTTP 429) and aborting the whole download.
  - A pinned-browser cookie attempt that hits the JS challenge now retries once
    without cookies, so public videos still download.
  - Duplicate detection no longer lower-cases the URL, so links that differ only
    by a case-sensitive video id are no longer wrongly treated as duplicates.

### Added
- **Video Downloader** subtitle setting: choose Off, English only,
  English + system language, or All languages.
- Failed downloads now show the error message inline (selectable to copy), in a
  taller window.

## [0.9.1] — 2026-06-19

### Fixed
- Window Manager now opens its panel immediately when launched from the Tool Box
  while it is not already running.
- Window Manager better preserves the intended target window across menu-bar
  opens, same-app window selections, keypad Return shortcuts, and multi-display
  status-item placement.
- Uninstaller search can no longer leave a hidden previously selected app active
  in the details pane while the filtered sidebar shows different results.

## [0.9.0] — 2026-06-11

### Added
- **Audio Router** — a new menu bar tool for virtual audio routing:
  - **Virtual cables** for app‑to‑app audio. Ships a pre‑built pool of
    independent loopback drivers (BlackHole instances, each with its own device
    identity) that can be installed/removed individually, so several apps can run
    on isolated cables at once (e.g. Discord, Zoom, OBS, Meet).
  - **Mirror / aggregate device builder** — combine inputs or mirror playback to
    several outputs at once, saved as reusable presets.
  - **Listen to an input** — play any input device (mic, line‑in, or a cable)
    through a chosen output in real time (macOS equivalent of Windows' "Listen to
    this device"), with multiple simultaneous monitors and per‑monitor level.

### Fixed
- **Volume Mixer** no longer silences or distorts an app when routing it to a
  non‑default output (including HDMI/TV devices). Routing now uses a process‑wide
  stereo‑mixdown tap instead of a device‑scoped one (which captured silence on
  some setups), and reconciles the sample rates of the source and routed outputs
  to a common rate so fixed‑rate outputs no longer drop to silence.
- **Volume Mixer** routed‑playback level calibration: the render loop now maps
  the tap's stereo frames onto the routed output's channel layout instead of
  copying raw interleaved bytes. On outputs whose streams aren't plain stereo
  (mono endpoints, 5.1/7.1 HDMI TVs and AVRs) the raw copy smeared frames
  across channels, heard as quieter, garbled routed playback. Stereo now lands
  on the front pair, unfed speaker channels get silence, and mono outputs get
  the averaged pair. On stereo outputs the path is measured bit‑exact at
  gain 1.0 — routed playback already matches direct playback level, so no
  blanket makeup gain is applied.

## [0.8.8] — 2026-06-10

### Added
- Window Manager: keyboard shortcuts are remappable — click a shortcut in the
  new Keyboard Shortcuts section, press the new combo, done. Includes reset to
  defaults, duplicate prevention, and clear notices when a shortcut can't
  register or when macOS secure input is blocking hotkeys system-wide.
- Window Manager: the popover shows "Will snap: <app>" so the target window is
  always visible before clicking a tile.

### Fixed
- Window Manager: snapping targets the window you were just working in, even
  when the popover is opened from a different display's menu bar (macOS moves
  focus to that display's topmost app with separate Spaces enabled).
- Window Manager: windows that were manually resized smaller now snap to the
  full half/corner size; apps flagged by assistive or automation software
  (AXEnhancedUserInterface) no longer silently ignore the resize.
- Clipboard: pasting goes to the app you were working in before opening the
  panel, fixing wrong-app pastes when summoning the clipboard from another
  display.
- Tool Box: quitting while an update is staged for install no longer risks
  aborting the installation.

### Changed
- All helper tools now share one window/panel implementation instead of
  near-identical copies, shrinking the codebase and making panel behavior
  uniform across tools.
- Release pipeline hygiene: signing secrets are scoped to only the steps that
  need them, the build keychain uses a random password and is cleaned up after
  every run, and CI actions are pinned to commit hashes.

## [0.8.7] — 2026-06-10

### Fixed
- Window Manager: each snap shortcut (⌃⌥ arrows/↩/C) now performs its own
  action; previously every shortcut triggered the same one.
- Window Manager: opening the popover no longer steals focus from the active
  app, so the snap tiles act on the window you were actually using.
- Automatic update checks now start when the Tool Box launches; previously
  updates were only found via a manual check.
- Volume Mixer: attenuating an app on the default output no longer rebuilds
  the audio tap every two seconds, removing the periodic audio blips.
- Volume Mixer: volume and pin settings now persist for apps without a bundle
  identifier (command-line players and similar).
- Volume Mixer: unmuting an app restores its previous level instead of jumping
  to 100%, and the per-app play/stop buttons now stick instead of being
  overridden by the automatic processing a couple of seconds later.
- Volume Mixer: apps paused while attenuated resume at the set volume instead
  of playing at full volume until processing re-engages.
- Clipboard and System Monitor login items broken by the app's rename to
  "DMonte Tool Box" are repaired automatically when the Tool Box launches.
- Disk Usage Analyzer no longer freezes the interface for several seconds when
  a large scan finishes; the tree index is built in the background.
- Clean Drive's cleaning bar drains over the selected items instead of
  plunging when only part of the junk was selected.
- Control-clicking any tray icon now opens the right-click menu.

### Changed
- README now documents all 19 tools, including the Volume Mixer.

### Security
- Release pipeline hardening: published releases can no longer be silently
  replaced (republishing requires an explicit manual override and preserves
  the prior artifact), releases are always built from the source of their
  tag, the bundled yt-dlp is pinned to a checksum-verified version (failing
  closed), and a signed build that cannot be notarized now fails the release
  instead of publishing a Gatekeeper-blocked app.

## [0.8.6] — 2026-06-10

### Added
- The Tool Box tray icon's right-click menu now includes a Check for Updates
  action.

### Fixed
- Checking for updates from Tool Box settings now closes the settings panel
  before Sparkle shows its update dialog, so reopening the Tool Box returns to
  the dashboard.
- Disk Usage Analyzer keeps scans running in the background when switching
  drives; scans pause only when the pause button is clicked.
- Disk Usage Analyzer scan progress no longer reports percentages above 100%
  when scanned bytes exceed the volume estimate; folder traversal progress is
  folded into the displayed percentage instead.

## [0.8.5] — 2026-06-10

### Fixed
- Sparkle update details now mark embedded release notes as Markdown so headings
  and lists render as rich text instead of showing raw Markdown syntax.

## [0.8.4] — 2026-06-10

### Changed
- Sparkle update details now use embedded release notes only, so the update
  pane shows the release's notes instead of the full GitHub release page.

## [0.8.3] — 2026-06-10

### Changed
- System Monitor and Grab Text use a higher-contrast green treatment in the
  Tool Box grid.
- System Monitor's menu bar ECG glyph now uses the same stronger green.

### Fixed
- Sparkle update-check dialogs are forced in front of the Tool Box panel so the
  "you're up to date" window remains clickable.

## [0.8.2] — 2026-06-10

### Added
- Right-click context menus on the Tool Box and menu bar tool icons now include
  a Quit action.

### Changed
- Sparkle automatic update checks are enabled by default and run daily.
- Release appcasts now embed release notes from the GitHub release body, with a
  changelog fallback.

### Fixed
- Sparkle's "you're up to date" dialog no longer gets trapped behind the Tool
  Box settings panel.

## [0.8.1] — 2026-06-09

### Added
- Disk Usage Analyzer now includes a side tree for navigating scanned folders.
- Volume Mixer now exposes master output volume and mute controls above the app list.
- Recently used toolbox items can be removed with a hover `x`.

### Changed
- Disk Usage Analyzer uses cached tree paths and treemap layouts for smoother navigation.
- Video Downloader reveals the completed output file when yt-dlp reports one, falling back to the save folder.

## [0.8.0] — 2026-06-09

### Added
- **Volume Mixer** — a new separate menu bar tool for per-app volume control
  using CoreAudio process taps. It lists active and inactive apps, groups helper
  processes under their parent app, supports mute, pinning, smart pinning,
  search, ignored-app management, and per-app output routing.

### Changed
- Volume Mixer restores saved app volume and routing state as soon as its tray
  helper starts, without needing to open the popover first.
- Volume Mixer is 200px taller, giving the app and ignored lists more room.
- Volume Mixer refresh work now runs off the main thread, slider persistence is
  debounced, and the real-time render path uses Accelerate for lower overhead.

## [0.7.1] — 2026-06-01

### Fixed
- **Menu bar icons no longer disappear.** Each tool's icon was hosted as a custom
  subview on the status button, leaving the button itself empty — so when the
  menu bar got crowded macOS culled the "empty" items. All icons now use the
  status item's native button, which AppKit keeps put.
- **Toolbox icon styling.** The hand‑drawn toolbox glyph rendered solid black;
  it's now an adaptive template (semi‑transparent white on dark menu bars) that
  highlights on hover, consistent with every other tool.
- **Launching the Tool Box no longer reopens previously‑open tools.** The
  session‑restore behaviour misfired because a menu‑bar app rarely gets a clean
  termination, so the saved set persisted and tools reopened on nearly every
  launch. Removed entirely — tools open only when you click them.

### Changed
- **Video Downloader**: clicking a completed download now reveals its folder in
  Finder (failed → retry, complete → reveal, otherwise → copy).
- **Clean Drive**: the progress bar's drain is rate‑limited so a fast/instant
  clean still shows a fluid sweep instead of snapping to empty.

## [0.7.0] — 2026-06-01

First public release. 🎉

### Added
- **Public distribution**: releases are now signed with Developer ID under the
  Hardened Runtime and **notarized + stapled by Apple** in CI, so downloads open
  without Gatekeeper warnings.
- A version label in the Tool Box settings sheet (sourced from the bundle).

The suite now ships **18 tools**: System Monitor, Clipboard History, Clean Drive,
Disk Usage Analyzer, Duplicate Finder, Uninstall Apps, Download Video, Image
Converter, Grab Text (OCR), QR Studio, Color Picker, Window Manager, Audio
Switcher, Focus Timer, Calendar, Keep Awake, Maintenance, and Dev Tools.

### Changed
- Notarization pipeline: inside‑out signing of every nested helper, the Sparkle
  framework's XPC services / updater, and the bundled yt‑dlp, each with the
  correct entitlements. `-rc` tags publish as prereleases that bypass the
  auto‑update feed.

## [0.6.1] — 2026-05-30

### Fixed
- **Third‑party review follow‑ups.** Audio Switcher and Maintenance now respect
  the display/menu‑bar scale and no longer cast a square shadow halo; Duplicate
  Finder's result rows scale with the window.
- **Security hardening.** Clipboard history is stored with owner‑only
  permissions (`0700`/`0600`); the bundled yt‑dlp download is verified against
  its official SHA‑256 checksum.

## [0.6.0] — 2026-05-30

### Added
- **Window Manager** — snap the focused window to halves, thirds, two‑thirds,
  corners, maximize, and center, with global ⌃⌥ shortcuts via the Accessibility
  API and multi‑display awareness.

### Changed
- Toolbox wiring is now driven by a single data‑driven `ToolboxCatalog`
  (dashboard, launcher, and packaging in lockstep); `package_app.sh` became
  table‑driven.
- Replaced the deprecated `NSStatusItem.view` with a shared status‑bar helper,
  clearing the macOS 10.14 deprecation warnings.

### Fixed
- Code‑review fixes: a Maintenance shell‑pipe deadlock, a Duplicate Finder scan
  race, Clipboard HTML‑only hashing and file‑paste self‑capture, and a release
  build data race.

## [0.5.0] — 2026-05-29

### Added
- **Eleven new tools**: Dev Tools, QR Studio, Keep Awake, Image Converter,
  Maintenance, Color Picker, Grab Text (OCR), Focus Timer, Duplicate Finder,
  Audio Switcher, and Calendar — each with a tested, pure‑logic core.

## [0.4.0] — 2026-05-29

### Added
- **Clipboard History** — searchable clipboard with text/rich‑text/link/image/
  file capture, pinning, quick‑paste (⌘1–9), paste‑as‑plain, and a ⇧⌘V global
  hotkey. Honors password‑manager/transient markers.

### Fixed
- The Tool Box search field is now focusable and clickable.

## [0.3.0] — 2026-05-29

### Changed
- **Clean Drive** now permanently frees space (instead of moving to Trash),
  runs asynchronously with a draining progress gauge, reports why anything was
  skipped, and tracks the macOS display scale.

## [0.2.0] — earlier

### Added
- Disk Usage Analyzer, Uninstall Apps, and Download Video tools; the tool box
  dashboard and Sparkle‑based auto‑updates.

## [0.1.x] — initial

### Added
- The menu bar tool box shell and the first tool, System Monitor (live CPU,
  memory, disk, network, and temperature metrics).

[Unreleased]: https://github.com/havokentity/MacTools/compare/v0.13.0...HEAD
[0.13.0]: https://github.com/havokentity/MacTools/releases/tag/v0.13.0
[0.12.0]: https://github.com/havokentity/MacTools/releases/tag/v0.12.0
[0.11.0]: https://github.com/havokentity/MacTools/releases/tag/v0.11.0
[0.10.0]: https://github.com/havokentity/MacTools/releases/tag/v0.10.0
[0.9.1]: https://github.com/havokentity/MacTools/releases/tag/v0.9.1
[0.9.0]: https://github.com/havokentity/MacTools/releases/tag/v0.9.0
[0.8.8]: https://github.com/havokentity/MacTools/releases/tag/v0.8.8
[0.8.7]: https://github.com/havokentity/MacTools/releases/tag/v0.8.7
[0.8.6]: https://github.com/havokentity/MacTools/releases/tag/v0.8.6
[0.8.5]: https://github.com/havokentity/MacTools/releases/tag/v0.8.5
[0.8.4]: https://github.com/havokentity/MacTools/releases/tag/v0.8.4
[0.8.3]: https://github.com/havokentity/MacTools/releases/tag/v0.8.3
[0.8.2]: https://github.com/havokentity/MacTools/releases/tag/v0.8.2
[0.8.1]: https://github.com/havokentity/MacTools/releases/tag/v0.8.1
[0.8.0]: https://github.com/havokentity/MacTools/releases/tag/v0.8.0
[0.7.1]: https://github.com/havokentity/MacTools/releases/tag/v0.7.1
[0.7.0]: https://github.com/havokentity/MacTools/releases/tag/v0.7.0
[0.6.1]: https://github.com/havokentity/MacTools/releases/tag/v0.6.1
[0.6.0]: https://github.com/havokentity/MacTools/releases/tag/v0.6.0
[0.5.0]: https://github.com/havokentity/MacTools/releases/tag/v0.5.0
[0.4.0]: https://github.com/havokentity/MacTools/releases/tag/v0.4.0
[0.3.0]: https://github.com/havokentity/MacTools/releases/tag/v0.3.0
[0.2.0]: https://github.com/havokentity/MacTools/releases/tag/v0.2.0
