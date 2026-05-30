#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/DMonte Toolbox.app"
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
  "DMonteCalendar|DMonte Calendar.app|CalendarInfo.plist"
  "DMonteColorPicker|DMonte Color Picker.app|ColorPickerInfo.plist"
  "DMonteGrabText|DMonte Grab Text.app|GrabTextInfo.plist"
  "DMonteFocusTimer|DMonte Focus Timer.app|FocusTimerInfo.plist"
)

stamp_version() {
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$1"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$1"
}

cd "$ROOT_DIR"
swift build -c release

YTDLP_PATH="$("$ROOT_DIR/Scripts/fetch_yt_dlp.sh")"

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

if [[ -d "$ROOT_DIR/.build/release/Sparkle.framework" ]]; then
  cp -R "$ROOT_DIR/.build/release/Sparkle.framework" "$FRAMEWORKS_DIR/"
fi

install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/DMonte" 2>/dev/null || true

stamp_version "$INFO_PLIST"

if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$INFO_PLIST"
fi

# Sign with a stable Developer ID identity so TCC grants (e.g. Full Disk Access)
# persist across rebuilds and moves — they key on bundle id + team, not the
# binary hash. The identity is never hard-coded here (this repo is public):
# it comes from the CODESIGN_IDENTITY env var, else the local keychain's
# Developer ID, else falls back to an ad-hoc signature.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  # `|| true` so a no-match (e.g. CI runners with no Developer ID) doesn't trip
  # `set -o pipefail` and abort the build — we just fall back to ad-hoc below.
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 'Developer ID Application' \
    | sed -E 's/^[^"]*"([^"]+)".*/\1/' || true)"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Signed ad-hoc (TCC grants will not persist across rebuilds)"
else
  echo "Signed with local Developer ID identity"
fi

echo "Created $APP_DIR"
