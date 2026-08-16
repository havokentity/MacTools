#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/DMonte Tool Box.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
INFO_PLIST="$CONTENTS_DIR/Info.plist"

VERSION="${VERSION_OVERRIDE:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"

# Every bundled helper, as "executableName|App Display Name.app|PlistFile".
# Adding a tool = one row here, plus its Package.swift target and ToolboxCatalog entry.
HELPERS=(
  "DMonteSystemMonitor|DMonte System Monitor.app|SystemMonitorInfo.plist"
  "DMonteUninstaller|DMonte Uninstaller.app|UninstallerInfo.plist"
  "DMonteCleanDrive|DMonte Clean Drive.app|CleanDriveInfo.plist"
  "DMonteVideoDownloader|DMonte Video Downloader.app|VideoDownloaderInfo.plist"
  "DMonteDiskAnalyzer|DMonte Disk Analyzer.app|DiskAnalyzerInfo.plist"
  "DMonteClipboard|DMonte Clipboard.app|ClipboardInfo.plist"
  "DMonteDevTools|DMonte Dev Tools.app|DevToolsInfo.plist"
  "DMonteQR|DMonte QR.app|QRInfo.plist"
  "DMonteKeepAwake|DMonte Keep Awake.app|KeepAwakeInfo.plist"
  "DMonteImageConverter|DMonte Image Converter.app|ImageConverterInfo.plist"
  "DMonteMaintenance|DMonte Maintenance.app|MaintenanceInfo.plist"
  "DMonteDuplicateFinder|DMonte Duplicate Finder.app|DuplicateFinderInfo.plist"
  "DMonteAudioSwitcher|DMonte Audio Switcher.app|AudioSwitcherInfo.plist"
  "DMonteVolumeMixer|DMonte Volume Mixer.app|VolumeMixerInfo.plist"
  "DMonteAudioRouter|DMonte Audio Router.app|AudioRouterInfo.plist"
  "DMonteCalendar|DMonte Calendar.app|CalendarInfo.plist"
  "DMonteColorPicker|DMonte Color Picker.app|ColorPickerInfo.plist"
  "DMonteGrabText|DMonte Grab Text.app|GrabTextInfo.plist"
  "DMonteFocusTimer|DMonte Focus Timer.app|FocusTimerInfo.plist"
  "DMonteWindowManager|DMonte Window Manager.app|WindowManagerInfo.plist"
  "DMonteMicControl|DMonte Mic Control.app|MicControlInfo.plist"
  "DMonteSnippets|DMonte Snippets.app|SnippetsInfo.plist"
  "DMonteDriveEjector|DMonte Drive Ejector.app|DriveEjectorInfo.plist"
  "DMonteScratchpad|DMonte Scratchpad.app|ScratchpadInfo.plist"
  "DMonteNetworkInfo|DMonte Network Info.app|NetworkInfoInfo.plist"
  "DMonteVideoSplitter|DMonte Video Splitter.app|VideoSplitterInfo.plist"
)

stamp_version() {
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$1"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$1"
}

cd "$ROOT_DIR"
swift build -c release

YTDLP_PATH="$("$ROOT_DIR/Scripts/fetch_yt_dlp.sh")"

# Static ffmpeg + ffprobe for the Video Downloader's merge/recode step (needed for
# X, Instagram, YouTube Shorts, and any non-progressive source). Fatal on failure:
# a release that can't merge is broken. Override/skip via the env vars documented
# in fetch_ffmpeg.sh.
FFMPEG_DIR="$("$ROOT_DIR/Scripts/fetch_ffmpeg.sh")"

# Deno runtime so yt-dlp can solve YouTube's JavaScript n-challenge (required for
# cookie'd requests and increasingly in general). Fatal on failure like yt-dlp.
DENO_DIR="$("$ROOT_DIR/Scripts/fetch_deno.sh")"

# Pool of virtual cables for the Audio Router tool. Non-fatal: if the build
# fails (offline / no Xcode), the tool still ships and works for mirror/combine —
# it just can't offer one-click cable install until a pool is present.
#
# stderr is captured to a file rather than discarded: it carries the noisy
# xcodebuild log (unwanted on the normal path) but ALSO the pinned-commit
# failure's expected-vs-actual hashes, which are the whole point of that guard
# and must reach the build log. Telling the operator to "re-run for details"
# would not do: on an ephemeral CI runner the re-run is a fresh clone, and the
# source that failed the check is already gone.
BLACKHOLE_STATUS=0
BLACKHOLE_LOG="$(mktemp)"
trap 'rm -f "$BLACKHOLE_LOG"' EXIT
BLACKHOLE_POOL_DIR="$("$ROOT_DIR/Scripts/fetch_blackhole.sh" 2>"$BLACKHOLE_LOG")" || BLACKHOLE_STATUS=$?
# Exit 2 is the one failure we must NOT shrug off: the upstream source didn't
# match its pinned commit, i.e. the tag moved. Never build past that.
if [[ "$BLACKHOLE_STATUS" -eq 2 ]]; then
  cat "$BLACKHOLE_LOG" >&2
  echo "error: BlackHole source failed its pinned-commit check — refusing to build" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

# Main toolbox executable, icon, and Info.plist.
cp "$ROOT_DIR/.build/release/DMonte" "$MACOS_DIR/DMonte"
cp "$ROOT_DIR/Packaging/Info.plist" "$INFO_PLIST"
cp "$ROOT_DIR/Packaging/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

# Each helper: build its bundle, copy the binary + Info.plist, stamp the version.
for entry in "${HELPERS[@]}"; do
  IFS='|' read -r exe app plist <<< "$entry"
  helper_macos="$HELPERS_DIR/$app/Contents/MacOS"
  helper_plist="$HELPERS_DIR/$app/Contents/Info.plist"
  mkdir -p "$helper_macos"
  cp "$ROOT_DIR/.build/release/$exe" "$helper_macos/$exe"
  cp "$ROOT_DIR/Packaging/$plist" "$helper_plist"
  stamp_version "$helper_plist"
done

# Video Downloader ships bundled yt-dlp + ffmpeg/ffprobe in its Resources/bin, so
# downloads (including merges and recodes) work without any system install.
#
# The Video Splitter helper reads ffmpeg/ffprobe from this exact path rather than
# carrying its own copies — they are 126 MB and both helpers ship inside the same
# signed container. If these binaries ever move or this helper is renamed, update
# VideoSplitterTools.siblingVideoDownloaderBinDirectory to match, or the splitter
# silently falls back to a system ffmpeg the user may not have.
VIDEO_DOWNLOADER_RESOURCES_DIR="$HELPERS_DIR/DMonte Video Downloader.app/Contents/Resources"
VIDEO_DOWNLOADER_BIN_DIR="$VIDEO_DOWNLOADER_RESOURCES_DIR/bin"
mkdir -p "$VIDEO_DOWNLOADER_BIN_DIR"
cp "$YTDLP_PATH" "$VIDEO_DOWNLOADER_BIN_DIR/yt-dlp"
cp "$FFMPEG_DIR/ffmpeg" "$VIDEO_DOWNLOADER_BIN_DIR/ffmpeg"
cp "$FFMPEG_DIR/ffprobe" "$VIDEO_DOWNLOADER_BIN_DIR/ffprobe"
cp "$DENO_DIR/deno" "$VIDEO_DOWNLOADER_BIN_DIR/deno"
chmod 755 "$VIDEO_DOWNLOADER_BIN_DIR/yt-dlp" "$VIDEO_DOWNLOADER_BIN_DIR/ffmpeg" "$VIDEO_DOWNLOADER_BIN_DIR/ffprobe" "$VIDEO_DOWNLOADER_BIN_DIR/deno"
xattr -cr "$VIDEO_DOWNLOADER_BIN_DIR/yt-dlp" "$VIDEO_DOWNLOADER_BIN_DIR/ffmpeg" "$VIDEO_DOWNLOADER_BIN_DIR/ffprobe" "$VIDEO_DOWNLOADER_BIN_DIR/deno" 2>/dev/null || true
# Ship the bundled tools' license/credits (FFmpeg is GPL, Deno is MIT).
cp "$ROOT_DIR/Packaging/FFmpeg-CREDITS.txt" "$VIDEO_DOWNLOADER_RESOURCES_DIR/FFmpeg-CREDITS.txt"
cp "$ROOT_DIR/Packaging/Deno-CREDITS.txt" "$VIDEO_DOWNLOADER_RESOURCES_DIR/Deno-CREDITS.txt"

# Audio Router ships the pool of virtual-cable drivers in Resources/Cables, each
# ready to be copied to /Library/Audio/Plug-Ins/HAL/ by the in-app installer.
AUDIO_ROUTER_CABLES_DIR="$HELPERS_DIR/DMonte Audio Router.app/Contents/Resources/Cables"
if [[ -n "$BLACKHOLE_POOL_DIR" && -d "$BLACKHOLE_POOL_DIR" ]] \
   && compgen -G "$BLACKHOLE_POOL_DIR/*.driver" >/dev/null; then
  mkdir -p "$AUDIO_ROUTER_CABLES_DIR"
  for cable in "$BLACKHOLE_POOL_DIR"/*.driver; do
    dest="$AUDIO_ROUTER_CABLES_DIR/$(basename "$cable")"
    rm -rf "$dest"
    cp -R "$cable" "$dest"
    xattr -cr "$dest" 2>/dev/null || true
  done
  echo "Bundled $(find "$AUDIO_ROUTER_CABLES_DIR" -maxdepth 1 -name '*.driver' | wc -l | tr -d ' ') virtual cables" >&2
else
  echo "note: no virtual-cable pool bundled; Audio Router cable install will be unavailable" >&2
fi

if [[ -d "$ROOT_DIR/.build/release/Sparkle.framework" ]]; then
  cp -R "$ROOT_DIR/.build/release/Sparkle.framework" "$FRAMEWORKS_DIR/"
fi

install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/DMonte" 2>/dev/null || true

stamp_version "$INFO_PLIST"

if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$INFO_PLIST"
fi

# ---------------------------------------------------------------------------
# Code signing
#
# Sign with a stable Developer ID identity so TCC grants (e.g. Full Disk Access)
# persist across rebuilds and moves — they key on bundle id + team, not the
# binary hash. The identity is never hard-coded here (this repo is public):
# it comes from the CODESIGN_IDENTITY env var, else the local keychain's
# Developer ID, else falls back to an ad-hoc signature.
#
# For PUBLIC DISTRIBUTION we sign with the Hardened Runtime + a secure timestamp,
# which Apple requires for notarization. Apple deprecated `--deep`, so we sign
# every nested executable INSIDE-OUT (deepest first, outer bundle last): yt-dlp,
# then the Sparkle framework's XPC services / Updater / Autoupdate / framework,
# then each helper .app, then the outer app. Each component is sealed before the
# thing that contains it, or the outer signature is invalidated.
# ---------------------------------------------------------------------------
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  # `|| true` so a no-match (e.g. CI runners with no Developer ID) doesn't trip
  # `set -o pipefail` and abort the build — we just fall back to ad-hoc below.
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Developer ID Application' \
    | sed -E 's/^[^"]*"([^"]+)".*/\1/' || true)"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

BASE_ENTITLEMENTS="$ROOT_DIR/Packaging/DMonte.entitlements"
APP_ENTITLEMENTS="$ROOT_DIR/Packaging/DMonteApp.entitlements"
VOLUMEMIXER_ENTITLEMENTS="$ROOT_DIR/Packaging/VolumeMixer.entitlements"
AUDIOROUTER_ENTITLEMENTS="$ROOT_DIR/Packaging/AudioRouter.entitlements"
CALENDAR_ENTITLEMENTS="$ROOT_DIR/Packaging/Calendar.entitlements"
YTDLP_ENTITLEMENTS="$ROOT_DIR/Packaging/ytdlp.entitlements"

# Hardened runtime + secure timestamp are only meaningful with a real identity;
# an ad-hoc signature (used on CI runners with no Developer ID) can't carry them
# and can't be notarized, so we sign ad-hoc-but-plain there for local testing.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  HARDENED_OPTS=()
  echo "No Developer ID found — signing ad-hoc (not hardened, cannot be notarized)"
else
  HARDENED_OPTS=(--options runtime --timestamp)
fi

# sign_one <path> <entitlements-or-empty>
sign_one() {
  local target="$1"
  local entitlements="${2:-}"
  local args=(--force --sign "$SIGN_IDENTITY")
  if [[ ${#HARDENED_OPTS[@]} -gt 0 ]]; then
    args+=("${HARDENED_OPTS[@]}")
  fi
  if [[ -n "$entitlements" ]]; then
    args+=(--entitlements "$entitlements")
  fi
  codesign "${args[@]}" "$target"
}

# 1. Deepest first: the bundled yt-dlp child process (relaxed entitlements).
if [[ -f "$VIDEO_DOWNLOADER_BIN_DIR/yt-dlp" ]]; then
  sign_one "$VIDEO_DOWNLOADER_BIN_DIR/yt-dlp" "$YTDLP_ENTITLEMENTS"
fi

# 1a. The bundled ffmpeg/ffprobe. They're self-contained static Mach-O binaries
# (system-linked only), so the Hardened Runtime needs no extra entitlements —
# unlike yt-dlp's PyInstaller bundle. Re-signed with our identity so the whole app
# notarizes as one unit.
for ffmpeg_tool in ffmpeg ffprobe; do
  if [[ -f "$VIDEO_DOWNLOADER_BIN_DIR/$ffmpeg_tool" ]]; then
    sign_one "$VIDEO_DOWNLOADER_BIN_DIR/$ffmpeg_tool"
  fi
done

# 1b. The bundled deno. Its V8 engine JIT-compiles, so under the Hardened Runtime
# it needs the same JIT/unsigned-memory relaxations as yt-dlp's interpreter.
if [[ -f "$VIDEO_DOWNLOADER_BIN_DIR/deno" ]]; then
  sign_one "$VIDEO_DOWNLOADER_BIN_DIR/deno" "$YTDLP_ENTITLEMENTS"
fi

# 1b. The bundled virtual-cable drivers (re-signed with our Developer ID so the
# whole app notarizes as one unit). Sign each one's inner Mach-O, then the
# bundle, before the helper app that contains them is sealed below.
if [[ -d "$AUDIO_ROUTER_CABLES_DIR" ]]; then
  for cable in "$AUDIO_ROUTER_CABLES_DIR"/*.driver; do
    [[ -d "$cable" ]] || continue
    cable_binary="$(find "$cable/Contents/MacOS" -maxdepth 1 -type f 2>/dev/null | head -n 1)"
    [[ -n "$cable_binary" ]] && sign_one "$cable_binary" "$BASE_ENTITLEMENTS"
    sign_one "$cable" "$BASE_ENTITLEMENTS"
  done
fi

# 2. Sparkle's nested code, then the framework itself.
SPARKLE_FW="$FRAMEWORKS_DIR/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  SPARKLE_V="$SPARKLE_FW/Versions/B"
  # XPC services and the updater apps each carry their own bundled binaries.
  for xpc in "$SPARKLE_V/XPCServices/Downloader.xpc" "$SPARKLE_V/XPCServices/Installer.xpc"; do
    [[ -d "$xpc" ]] && sign_one "$xpc"
  done
  [[ -e "$SPARKLE_V/Autoupdate" ]] && sign_one "$SPARKLE_V/Autoupdate"
  if [[ -d "$SPARKLE_V/Updater.app" ]]; then
    # Updater.app's own executable, then the .app wrapper.
    sign_one "$SPARKLE_V/Updater.app/Contents/MacOS/Updater" 2>/dev/null || true
    sign_one "$SPARKLE_V/Updater.app"
  fi
  sign_one "$SPARKLE_FW"
fi

# 3. Each helper .app (their executables are simple Swift binaries → base entitlements).
for entry in "${HELPERS[@]}"; do
  IFS='|' read -r exe app plist <<< "$entry"
  helper_entitlements="$BASE_ENTITLEMENTS"
  if [[ "$exe" == "DMonteVolumeMixer" ]]; then
    helper_entitlements="$VOLUMEMIXER_ENTITLEMENTS"
  elif [[ "$exe" == "DMonteAudioRouter" ]]; then
    # Needs the audio-input entitlement for the "listen to an input" monitor.
    helper_entitlements="$AUDIOROUTER_ENTITLEMENTS"
  elif [[ "$exe" == "DMonteCalendar" ]]; then
    # Hardened Runtime refuses a calendar prompt without this entitlement.
    helper_entitlements="$CALENDAR_ENTITLEMENTS"
  fi
  sign_one "$HELPERS_DIR/$app/Contents/MacOS/$exe" "$helper_entitlements"
  sign_one "$HELPERS_DIR/$app" "$helper_entitlements"
done

# 4. Finally the outer app (seals everything signed above). It signs with
# APP_ENTITLEMENTS, not BASE_ENTITLEMENTS: TCC attributes a nested helper's
# microphone use to the container, so the audio-input entitlement has to be
# here as well as on the Audio Router helper. See DMonteApp.entitlements.
sign_one "$APP_DIR" "$APP_ENTITLEMENTS"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Signed ad-hoc (TCC grants will not persist; not notarizable)"
else
  echo "Signed with Developer ID + Hardened Runtime (notarization-ready)"
  # Fail fast if the seal isn't valid for distribution.
  codesign --verify --deep --strict --verbose=1 "$APP_DIR"
fi

echo "Created $APP_DIR"
