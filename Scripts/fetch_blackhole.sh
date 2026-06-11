#!/usr/bin/env bash
set -euo pipefail

# Builds a POOL of independent virtual audio cables for the Audio Router tool.
#
# Each cable is its own BlackHole instance built from a pinned source tag with a
# unique kDriver_Name (which BlackHole uses to derive the device UID/name) and a
# unique bundle id, so the instances coexist as fully separate devices. We
# pre-build the pool here because end-user machines have no compiler — the app
# bundles the pool and installs/removes individual cables on demand.
#
# package_app.sh re-signs each product with our Developer ID so the whole app
# notarizes as one unit. Requires a full Xcode toolchain (xcodebuild).
#
# Prints the absolute path to the directory holding the built *.driver pool.
#
# Naming convention (MUST match LoopbackDriverInstaller in Swift):
#   index n -> kDriver_Name "DMonteCable<n>" (space-free: seeds the device UID),
#              visible device name "DMonte Cable <n>", bundle id
#              "com.havokentity.mactools.loopback.cable<n>",
#              file "DMonteCable<n>.driver"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/.build/vendor/blackhole"
SRC_DIR="$VENDOR_DIR/src"
POOL_DIR="$VENDOR_DIR/cables"
STAMP_PATH="$VENDOR_DIR/pool-stamp"

BLACKHOLE_VERSION="${BLACKHOLE_VERSION:-0.6.1}"
# How many independent cables to pre-build. Default covers several simultaneous
# apps (e.g. Discord, Zoom, OBS, Meet) with headroom.
CABLE_COUNT="${CABLE_COUNT:-6}"
REPO_URL="https://github.com/ExistentialAudio/BlackHole.git"

STAMP="v${BLACKHOLE_VERSION}-x${CABLE_COUNT}"

mkdir -p "$VENDOR_DIR"

# Reuse a previous pool when version + count match.
if [[ -f "$STAMP_PATH" && "$(cat "$STAMP_PATH")" == "$STAMP" ]] \
   && [[ "$(find "$POOL_DIR" -maxdepth 1 -name '*.driver' 2>/dev/null | wc -l | tr -d ' ')" == "$CABLE_COUNT" ]]; then
  echo "$POOL_DIR"
  exit 0
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found; cannot build the loopback cable pool" >&2
  exit 1
fi

echo "Cloning BlackHole v$BLACKHOLE_VERSION" >&2
rm -rf "$SRC_DIR" "$POOL_DIR"
git clone --depth 1 --branch "v$BLACKHOLE_VERSION" "$REPO_URL" "$SRC_DIR" >&2
mkdir -p "$POOL_DIR"

for ((n = 1; n <= CABLE_COUNT; n++)); do
  # kDriver_Name must be space-free: it seeds the device UID and is a
  # preprocessor define (xcodebuild splits defines on spaces). kDevice_Name is
  # the user-visible name in macOS Sound settings; spaces there are allowed but
  # must be backslash-escaped so xcodebuild keeps the macro as one token.
  driver_name="DMonteCable${n}"
  device_name="DMonte Cable ${n}"
  device_name_escaped="${device_name// /\\ }"
  bundle_id="com.havokentity.mactools.loopback.cable${n}"
  build_out="$VENDOR_DIR/build-${n}"
  rm -rf "$build_out"

  echo "Building cable ${n}/${CABLE_COUNT}: '${device_name}' ($bundle_id)" >&2
  # Unsigned (source pins someone else's team id); package_app.sh re-signs.
  xcodebuild \
    -project "$SRC_DIR/BlackHole.xcodeproj" \
    -target BlackHole \
    -configuration Release \
    CONFIGURATION_BUILD_DIR="$build_out" \
    PRODUCT_NAME="$driver_name" \
    PRODUCT_BUNDLE_IDENTIFIER="$bundle_id" \
    GCC_PREPROCESSOR_DEFINITIONS="\$(inherited) kDriver_Name=\\\"${driver_name}\\\" kPlugIn_BundleID=\\\"${bundle_id}\\\" kDevice_Name=\\\"${device_name_escaped}\\\" kNumber_Of_Channels=2" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM="" \
    >&2

  built="$(find "$build_out" -maxdepth 1 -type d -name '*.driver' | head -n 1)"
  if [[ -z "$built" ]]; then
    echo "Cable ${n} built but produced no .driver" >&2
    exit 1
  fi
  cp -R "$built" "$POOL_DIR/${driver_name}.driver"
  xattr -cr "$POOL_DIR/${driver_name}.driver" 2>/dev/null || true
  rm -rf "$build_out"
done

printf '%s' "$STAMP" > "$STAMP_PATH"
echo "$POOL_DIR"
