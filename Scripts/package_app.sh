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
SYSTEM_MONITOR_APP_DIR="$HELPERS_DIR/DMonte System Monitor.app"
SYSTEM_MONITOR_CONTENTS_DIR="$SYSTEM_MONITOR_APP_DIR/Contents"
SYSTEM_MONITOR_MACOS_DIR="$SYSTEM_MONITOR_CONTENTS_DIR/MacOS"
SYSTEM_MONITOR_INFO_PLIST="$SYSTEM_MONITOR_CONTENTS_DIR/Info.plist"
UNINSTALLER_APP_DIR="$HELPERS_DIR/DMonte Uninstaller.app"
UNINSTALLER_CONTENTS_DIR="$UNINSTALLER_APP_DIR/Contents"
UNINSTALLER_MACOS_DIR="$UNINSTALLER_CONTENTS_DIR/MacOS"
UNINSTALLER_INFO_PLIST="$UNINSTALLER_CONTENTS_DIR/Info.plist"
CLEAN_DRIVE_APP_DIR="$HELPERS_DIR/DMonte Clean Drive.app"
CLEAN_DRIVE_CONTENTS_DIR="$CLEAN_DRIVE_APP_DIR/Contents"
CLEAN_DRIVE_MACOS_DIR="$CLEAN_DRIVE_CONTENTS_DIR/MacOS"
CLEAN_DRIVE_INFO_PLIST="$CLEAN_DRIVE_CONTENTS_DIR/Info.plist"
VIDEO_DOWNLOADER_APP_DIR="$HELPERS_DIR/DMonte Video Downloader.app"
VIDEO_DOWNLOADER_CONTENTS_DIR="$VIDEO_DOWNLOADER_APP_DIR/Contents"
VIDEO_DOWNLOADER_MACOS_DIR="$VIDEO_DOWNLOADER_CONTENTS_DIR/MacOS"
VIDEO_DOWNLOADER_RESOURCES_DIR="$VIDEO_DOWNLOADER_CONTENTS_DIR/Resources"
VIDEO_DOWNLOADER_BIN_DIR="$VIDEO_DOWNLOADER_RESOURCES_DIR/bin"
VIDEO_DOWNLOADER_INFO_PLIST="$VIDEO_DOWNLOADER_CONTENTS_DIR/Info.plist"
DISK_ANALYZER_APP_DIR="$HELPERS_DIR/DMonte Disk Analyzer.app"
DISK_ANALYZER_CONTENTS_DIR="$DISK_ANALYZER_APP_DIR/Contents"
DISK_ANALYZER_MACOS_DIR="$DISK_ANALYZER_CONTENTS_DIR/MacOS"
DISK_ANALYZER_INFO_PLIST="$DISK_ANALYZER_CONTENTS_DIR/Info.plist"
CLIPBOARD_APP_DIR="$HELPERS_DIR/DMonte Clipboard.app"
CLIPBOARD_CONTENTS_DIR="$CLIPBOARD_APP_DIR/Contents"
CLIPBOARD_MACOS_DIR="$CLIPBOARD_CONTENTS_DIR/MacOS"
CLIPBOARD_INFO_PLIST="$CLIPBOARD_CONTENTS_DIR/Info.plist"
VERSION="${VERSION_OVERRIDE:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"

cd "$ROOT_DIR"
swift build -c release

YTDLP_PATH="$("$ROOT_DIR/Scripts/fetch_yt_dlp.sh")"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$SYSTEM_MONITOR_MACOS_DIR" "$UNINSTALLER_MACOS_DIR" "$CLEAN_DRIVE_MACOS_DIR" "$VIDEO_DOWNLOADER_MACOS_DIR" "$VIDEO_DOWNLOADER_BIN_DIR" "$DISK_ANALYZER_MACOS_DIR" "$CLIPBOARD_MACOS_DIR"

cp "$ROOT_DIR/.build/release/DMonte" "$MACOS_DIR/DMonte"
cp "$ROOT_DIR/.build/release/DMonteSystemMonitor" "$SYSTEM_MONITOR_MACOS_DIR/DMonteSystemMonitor"
cp "$ROOT_DIR/.build/release/DMonteUninstaller" "$UNINSTALLER_MACOS_DIR/DMonteUninstaller"
cp "$ROOT_DIR/.build/release/DMonteCleanDrive" "$CLEAN_DRIVE_MACOS_DIR/DMonteCleanDrive"
cp "$ROOT_DIR/.build/release/DMonteVideoDownloader" "$VIDEO_DOWNLOADER_MACOS_DIR/DMonteVideoDownloader"
cp "$ROOT_DIR/.build/release/DMonteDiskAnalyzer" "$DISK_ANALYZER_MACOS_DIR/DMonteDiskAnalyzer"
cp "$ROOT_DIR/.build/release/DMonteClipboard" "$CLIPBOARD_MACOS_DIR/DMonteClipboard"
cp "$YTDLP_PATH" "$VIDEO_DOWNLOADER_BIN_DIR/yt-dlp"
chmod 755 "$VIDEO_DOWNLOADER_BIN_DIR/yt-dlp"
xattr -cr "$VIDEO_DOWNLOADER_BIN_DIR/yt-dlp" 2>/dev/null || true
cp "$ROOT_DIR/Packaging/Info.plist" "$INFO_PLIST"
cp "$ROOT_DIR/Packaging/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/Packaging/SystemMonitorInfo.plist" "$SYSTEM_MONITOR_INFO_PLIST"
cp "$ROOT_DIR/Packaging/UninstallerInfo.plist" "$UNINSTALLER_INFO_PLIST"
cp "$ROOT_DIR/Packaging/CleanDriveInfo.plist" "$CLEAN_DRIVE_INFO_PLIST"
cp "$ROOT_DIR/Packaging/VideoDownloaderInfo.plist" "$VIDEO_DOWNLOADER_INFO_PLIST"
cp "$ROOT_DIR/Packaging/DiskAnalyzerInfo.plist" "$DISK_ANALYZER_INFO_PLIST"
cp "$ROOT_DIR/Packaging/ClipboardInfo.plist" "$CLIPBOARD_INFO_PLIST"

if [[ -d "$ROOT_DIR/.build/release/Sparkle.framework" ]]; then
  cp -R "$ROOT_DIR/.build/release/Sparkle.framework" "$FRAMEWORKS_DIR/"
fi

install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/DMonte" 2>/dev/null || true

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$SYSTEM_MONITOR_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$SYSTEM_MONITOR_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$UNINSTALLER_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$UNINSTALLER_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CLEAN_DRIVE_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CLEAN_DRIVE_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$VIDEO_DOWNLOADER_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$VIDEO_DOWNLOADER_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$DISK_ANALYZER_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$DISK_ANALYZER_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CLIPBOARD_INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CLIPBOARD_INFO_PLIST"

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
