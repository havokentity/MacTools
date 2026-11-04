# Follow-ups from the 2026-11 code review

Each item below was found during a full read of the sources but deliberately
left alone: it needs a design decision, a compiler to verify, or a Mac to test
on. The fixes that were safe to make blind shipped in 0.16.2 (see CHANGELOG).
Work these on a machine that can run `swift build` and `swift test`, then
package and install with `Scripts/package_app.sh` + `Scripts/install_to_applications.sh`
before handing back, per AGENTS.md.

## Main-thread stalls

- [ ] **Window Manager** — `WindowManagerController.swift` (`applyResult` /
  `setFrameVerified`): up to 3 attempts × 4 AX calls, each bounded by the 3 s
  messaging timeout, plus an 80 ms settle per attempt, all on the main actor. A
  beachballing target app freezes the helper (popover and hotkeys) for tens of
  seconds. Move the write/verify loop into a detached task and publish the
  result back; disable the tiles while an apply is in flight.
- [ ] **Drive Ejector** — `DriveEjectorController.refresh()` stats every mounted
  volume synchronously on the main actor (on each mount/unmount notification,
  panel open and eject completion). Network volumes are refused but still
  stat'ed, so a hung SMB/NFS mount blocks the UI for the vnode timeout. Read
  `DriveEjectorKit.ejectableVolumes()` off-actor with the supersede-on-cancel
  pattern `NetworkInfoController.refresh()` uses.
- [ ] **Disk Usage Analyzer** — `refreshVolumes` → `DiskVolumeProvider.mountedVolumes()`
  runs `resourceValues` for every mounted volume on the main actor before
  filtering on `volumeIsLocal`; same hung-network-mount stall at launch and on
  each refresh click. Needs `refreshVolumes` to become async (it drives
  `select`/`startScan`).
- [ ] **Dev Tools** — `DevToolsView.swift` (`TransformPane`, `HashPane`, `JWTPane`):
  JSON pretty-print, Base64, the four hashes and JWT decode run synchronously
  inside `body` on every keystroke. A multi-MB paste stalls the UI. Compute
  into `@State` from a debounced, cancellable `Task`.
- [ ] **File Shelf** — `FileShelfStore.shelve` re-resolves up to 50 bookmarks on
  the main actor inside the drop callback (the comment explains why it must
  de-duplicate; CHANGELOG 0.16.0 moved the other paths off-main). Resolve
  off-main and adopt under the generation gate, or re-resolve only rows whose
  cached inode no longer matches.
- [ ] **Image Converter** — `ImageConverterView.addURLs` stats each dropped file
  synchronously on the main actor although the comment above says sizes load
  off-main; `originalBytes` is read by `convertAll`, so either stat inside the
  convert task or correct the comment.
- [ ] **Clipboard History** — pasting an image entry decodes it and re-encodes
  TIFF on the main thread (`ClipboardPaste.swift` ~492), a 100–300 ms stall
  after the panel closes. Moving it off-main changes the activate → ⌘V timing,
  so test carefully.

## Process lifecycle

- [ ] **Video Splitter** — `VideoSplitterAppDelegate.applicationWillTerminate`
  does not cancel the ffmpeg workers, so a termination that bypasses
  `requestQuit` (kill, the Tool Box quitting helpers, `NSApp.terminate` from
  `onUserClosedWindow`) orphans up to 4 ffmpeg processes. Mirror the
  downloader's `VideoDownloaderProcesses.terminateAll` registry on
  `VideoSplitterRunner`.
- [ ] **Video Splitter** — `VideoSplitterRunner.cancel()` /
  `terminateRunningProcesses()` call `terminate()` on processes that may have
  exited between `waitUntilExit()` and their removal; guard with
  `where process.isRunning` as the downloader does.
- [ ] **Grab Text / QR Studio** — `GrabTextKit.swift` ~151 and `QRView.swift`
  ~681 call `process.waitUntilExit()` inside `Task.detached`, pinning a
  cooperative-pool thread for the whole interactive region selection. Replace
  with `terminationHandler` + `withCheckedContinuation`.
- [ ] **Audio Router** — `LoopbackDriverInstaller.runPrivileged` calls
  `waitUntilExit()` before draining its pipes; every current command emits at
  most a line, but a chatty one would deadlock on a full 64 KB pipe. Drain
  stderr on a background handler before waiting.

## Swallowed failures

- [ ] **File Shelf** — `FileShelfStore.adopt` ignores `FileShelfKit.write`'s
  `Bool`; an unwritable Application Support silently loses the shelf across
  relaunches. Set a warning on `false`, move the callers' `statusMessage = nil`
  ahead of `adopt`, and keep it out of `clearStatus()` on show.
- [ ] **Tool Box** — `AppDelegate.launchHelper` calls `openApplication` with no
  completion handler and the debug path uses `try? Process.run`; a damaged or
  quarantined helper fails silently and the popover just closes. Log via
  `os.Logger` at minimum, or show an alert.
- [ ] **Dev Tools** — `DevToolsKit.base64Decode` reports "Invalid Base64 input"
  when the input *is* valid Base64 but decodes to non-UTF-8 bytes (a base64'd
  PNG). Needs a new `DevToolsError` case and a `message(for:)` arm.

## Correctness edge cases

- [ ] **Snippets** — `commitEditor` clears `searchText` and selects the new
  snippet, but when a search was active the view's
  `.onChange(of: controller.searchText) { selectFirst() }` then moves the
  selection to the first row instead of the new snippet.
- [ ] **Video Splitter** — dropping a video that is already queued shows the
  "Only MP4, M4V, MOV, and MKV can be split" message because the duplicate and
  unsupported filters share one empty-result branch; needs an "Already in the
  queue" message.
- [ ] **Duplicate Finder** — `DuplicatesKit` (the public sibling engine in
  `DuplicateFinderKit.swift`, used only by tests) does not collapse hard links
  by inode and has no cancellation checks; copy `DuplicateFinderKit.distinctFiles`.
- [ ] **Duplicate Finder** — no "deletion in flight" flag: a second click on
  Delete during the trash loop re-trashes moved URLs and reports them as
  failures. Add `@Published var isDeleting` and gate the button.
- [ ] **Audio Router** — `addMonitor()` is async (the mic prompt can take
  seconds); a second click on Listen before it resolves starts two engines for
  the same pair. Needs a pending flag and a disabled button.
- [ ] **Disk Usage Analyzer** — `scheduleTreeCacheBuild` /
  `scheduleTreemapLayoutCache` remove their task entry by key before the
  staleness guard, so a superseded task can delete the newer task's entry
  (reachable during live resize). Move the `removeValue` after the generation
  guard, or key on a per-schedule token.
- [ ] **Audio Switcher** — `AudioSwitcherController.refresh()` publishes
  `defaultOutputID` / `defaultInputID` without a change guard, unlike the other
  properties. Harmless today; add the guard for consistency.
- [ ] **Status item anchoring** — `StatusItemAnchor.placedFrame` treats an item
  as placed only when `frame.midY > screen.visibleFrame.maxY`. Verify on a Mac
  with "Automatically hide and show the menu bar: Always" that panels still
  open under the icon rather than centred after the 2 s settle timeout.

## Performance (background, lower priority)

- [ ] **Clean Drive** — the clean re-walks every selected tree
  (`directorySize(at:)` per leaf) that `scan()` walked seconds earlier; on a
  large `~/Library/Caches` the UI sits at "Cleaning…" for the whole second
  walk. Have `scan()` return per-leaf work items.
- [ ] **Duplicate Finder** — every file in a same-size bucket is fully SHA-256'd
  before grouping; a first-chunk prefilter (hash 1 MiB, full-hash only
  sub-buckets with 2+ members) would skip same-size non-identical large files.
- [ ] **Disk Usage Analyzer** — `DiskTreemapLayoutCacheBuilder` precomputes
  squarify results for every directory on the volume at each treemap size and
  again on every resize (hundreds of thousands of entries on a boot volume).
  Memoize per visited directory, or at least debounce `updateTreemapSize`.
- [ ] **Disk Usage Analyzer** — hard links are counted once per directory entry,
  inflating totals; needs `ATTR_CMN_FILEID` + `ATTR_FILE_LINKCOUNT` and a
  cross-task seen-inode set.
- [ ] **Clipboard History** — `searchableText` allocates a lowercased copy of
  every entry's full text on every keystroke; cache per id (entries are
  immutable). Also no per-entry size cap: one 50 MB RTF copy makes every
  debounced save rewrite ~70 MB and `load()` decode it at launch; gate on the
  already-recorded `byteCount`.
- [ ] **Volume Mixer** — `responsiblePID(for:)` calls `dlsym` per audio process
  per poll; `normalizedDisplayName` builds two regexes per running app per
  poll; `processBundleID(for:)` is read twice per audio process. Hoist into
  `nonisolated(unsafe) static let`s / a local.
- [ ] **Image Converter** — `loadThumbnails` matches completions with
  `firstIndex { $0.url.standardizedFileURL == url.standardizedFileURL }`, O(n²)
  standardisations on the main actor for a large drop; both sides are already
  standardised, so compare `$0.url == url` or match by id.
- [ ] **File Shelf / Drive Ejector** — `NSWorkspace.shared.icon(forFile:)` runs
  in `body` per row per re-render (`FileShelfView.FileIcon`,
  `DriveEjectorView.VolumeIcon`). Cache the image per URL/volume id.
- [ ] **Calendar** — `CalendarKit.weekdaySymbols()` and `monthTitle()` build a
  `DateFormatter` on every render; cache in `CalendarController` keyed on the
  displayed month.
- [ ] **Sizing enums** — every `*Sizing.s()` re-reads `NSScreen.main` and
  `NSStatusBar.system.thickness` per call, hundreds of times per body
  evaluation across tools. A repo-wide decision; consider capturing scale once
  per view.
- [ ] **System Monitor** — `SystemMonitor` has no `deinit` invalidating its
  timer; moot while both app instances live for the process, but worth a
  `stop()` guarantee if it ever becomes per-window.
