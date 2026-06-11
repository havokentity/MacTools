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
)

stamp_version() {
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$1"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$1"
}

cd "$ROOT_DIR"
swift build -c release

YTDLP_PATH="$("$ROOT_DIR/Scripts/fetch_yt_dlp.sh")"

# Pool of virtual cables for the Audio Router tool. Non-fatal: if the build
# fails (offline / no Xcode), the tool still ships and works for mirror/combine —
# it just can't offer one-click cable install until a pool is present.
BLACKHOLE_POOL_DIR="$("$ROOT_DIR/Scripts/fetch_blackhole.sh" 2>/dev/null || true)"

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

# Video Downloader ships a bundled yt-dlp binary in its Resources/bin.
VIDEO_DOWNLOADER_BIN_DIR="$HELPERS_DIR/DMonte Video Downloader.app/Contents/Resources/bin"
mkdir -p "$VIDEO_DOWNLOADER_BIN_DIR"
cp "$YTDLP_PATH" "$VIDEO_DOWNLOADER_BIN_DIR/yt-dlp"
chmod 755 "$VIDEO_DOWNLOADER_BIN_DIR/yt-dlp"
xattr -cr "$VIDEO_DOWNLOADER_BIN_DIR/yt-dlp" 2>/dev/null || true

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
VOLUMEMIXER_ENTITLEMENTS="$ROOT_DIR/Packaging/VolumeMixer.entitlements"
AUDIOROUTER_ENTITLEMENTS="$ROOT_DIR/Packaging/AudioRouter.entitlements"
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
  fi
  sign_one "$HELPERS_DIR/$app/Contents/MacOS/$exe" "$helper_entitlements"
  sign_one "$HELPERS_DIR/$app" "$helper_entitlements"
done

# 4. Finally the outer app (seals everything signed above).
sign_one "$APP_DIR" "$BASE_ENTITLEMENTS"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Signed ad-hoc (TCC grants will not persist; not notarizable)"
else
  echo "Signed with Developer ID + Hardened Runtime (notarization-ready)"
  # Fail fast if the seal isn't valid for distribution.
  codesign --verify --deep --strict --verbose=1 "$APP_DIR"
fi

echo "Created $APP_DIR"
