#!/usr/bin/env bash
set -euo pipefail

# Fetches static macOS ffmpeg + ffprobe for the Video Downloader's merge/recode
# step and prints the directory that holds them (suitable for yt-dlp's
# --ffmpeg-location). Mirrors fetch_yt_dlp.sh: pinned version + SHA-256, verified
# fail-closed, so every build embeds the same vetted binaries.
#
# Source: https://ffmpeg.martin-riedl.de/ — native arm64 + amd64 static builds at
# immutable, per-build URLs, each with a published <file>.zip.sha256. These are
# GPL builds (configured with --enable-gpl --enable-libx264); MacTools itself is
# GPLv3, so bundling them is license-compatible. ffmpeg runs as a separate child
# process, never linked into the app. See the Video Downloader's Resources for the
# FFmpeg credits/source pointer shipped alongside the binaries.
#
# Bumping the pin: open https://ffmpeg.martin-riedl.de/, pick a macOS build, copy
# its per-arch build id (the "<timestamp>_<version>" path segment) and the
# ffmpeg.zip / ffprobe.zip SHA-256 values into the constants below. Or override per
# build with FFMPEG_VERSION / FFMPEG_BUILD_ARM64 / FFMPEG_BUILD_AMD64 and
# FFMPEG_SHA256 / FFPROBE_SHA256. With no pinned/override hash the script falls
# back to the provider's published .zip.sha256 and fails closed if none is found;
# FFMPEG_ALLOW_UNVERIFIED=1 downgrades that to a warning (local dev only).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/.build/vendor/ffmpeg"
VERSION_PATH="$VENDOR_DIR/version"

PINNED_FFMPEG_VERSION="8.1.1"
# Immutable per-arch build directories on the provider.
PINNED_BUILD_ARM64="1778761665_8.1.1"
PINNED_BUILD_AMD64="1778768838_8.1.1"
# SHA-256 of each .zip. arm64 is pinned (downloaded + verified to merge correctly);
# amd64 is left empty and verified against the provider's published checksum.
PINNED_ARM64_FFMPEG_SHA256="a05b1a47bb3ac89a95a55eec713f8bbb347051bb07015f3b7d08fb62ed81a21e"
PINNED_ARM64_FFPROBE_SHA256="135e70d2518beeb568183952dbc4bdeca1628dd49a7376d57e6b27dbc57d209f"
PINNED_AMD64_FFMPEG_SHA256=""
PINNED_AMD64_FFPROBE_SHA256=""

FFMPEG_VERSION="${FFMPEG_VERSION:-$PINNED_FFMPEG_VERSION}"

case "$(uname -m)" in
  arm64)
    ARCH_SLUG="arm64"
    BUILD="${FFMPEG_BUILD_ARM64:-$PINNED_BUILD_ARM64}"
    PINNED_FFMPEG_SHA256="$PINNED_ARM64_FFMPEG_SHA256"
    PINNED_FFPROBE_SHA256="$PINNED_ARM64_FFPROBE_SHA256"
    ;;
  x86_64)
    ARCH_SLUG="amd64"
    BUILD="${FFMPEG_BUILD_AMD64:-$PINNED_BUILD_AMD64}"
    PINNED_FFMPEG_SHA256="$PINNED_AMD64_FFMPEG_SHA256"
    PINNED_FFPROBE_SHA256="$PINNED_AMD64_FFPROBE_SHA256"
    ;;
  *)
    echo "unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

BASE_URL="https://ffmpeg.martin-riedl.de/download/macos/$ARCH_SLUG/$BUILD"
# The provider 403s requests without a browser-like User-Agent.
USER_AGENT="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
VERSION_TAG="$FFMPEG_VERSION-$ARCH_SLUG-$BUILD"

curl_args=(
  --fail
  --location
  --retry 5
  --retry-delay 2
  --retry-all-errors
  --connect-timeout 15
  --user-agent "$USER_AGENT"
)

mkdir -p "$VENDOR_DIR"

# Cached binaries from the same immutable build are trusted as-is.
if [[ -x "$VENDOR_DIR/ffmpeg" && -x "$VENDOR_DIR/ffprobe" \
      && -f "$VERSION_PATH" && "$(cat "$VERSION_PATH")" == "$VERSION_TAG" ]]; then
  echo "$VENDOR_DIR"
  exit 0
fi

# fetch_one <name> <pinned-sha> <override-sha>
fetch_one() {
  local name="$1"
  local pinned_sha="$2"
  local override_sha="$3"
  local url="$BASE_URL/$name.zip"
  local tmp_zip="$VENDOR_DIR/$name.zip.tmp"

  echo "Fetching $name from $url" >&2
  rm -f "$tmp_zip"
  curl "${curl_args[@]}" "$url" --output "$tmp_zip"

  local actual_sha
  actual_sha="$(shasum -a 256 "$tmp_zip" | awk '{print $1}')"

  # An explicit override wins, then the pinned hash, else the provider's published
  # checksum for this exact file. Verification is fail-closed.
  local expected_sha="$override_sha"
  [[ -z "$expected_sha" ]] && expected_sha="$pinned_sha"
  if [[ -z "$expected_sha" ]]; then
    expected_sha="$(curl --silent "${curl_args[@]}" "$url.sha256" 2>/dev/null | awk '{print $1}' | head -n 1 || true)"
  fi

  if [[ -z "$expected_sha" ]]; then
    if [[ "${FFMPEG_ALLOW_UNVERIFIED:-0}" == "1" ]]; then
      echo "warning: no SHA-256 to verify $name (got $actual_sha); continuing because FFMPEG_ALLOW_UNVERIFIED=1" >&2
    else
      # `tr`, not ${name^^}: stock macOS ships bash 3.2, where that expansion is
      # a "bad substitution" error — which would abort before this guidance prints.
      local upper_name
      upper_name="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
      echo "error: no SHA-256 to verify $name (got $actual_sha)" >&2
      echo "  set ${upper_name}_SHA256=<expected>, or FFMPEG_ALLOW_UNVERIFIED=1 for local dev only" >&2
      rm -f "$tmp_zip"
      exit 1
    fi
  elif [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "$name checksum mismatch for $VERSION_TAG" >&2
    echo "  expected: $expected_sha" >&2
    echo "  actual:   $actual_sha" >&2
    rm -f "$tmp_zip"
    exit 1
  else
    echo "$name checksum verified ($actual_sha)" >&2
  fi

  # Each archive holds a single binary named exactly like the tool.
  rm -f "$VENDOR_DIR/$name"
  unzip -oq "$tmp_zip" "$name" -d "$VENDOR_DIR"
  chmod 755 "$VENDOR_DIR/$name"
  xattr -cr "$VENDOR_DIR/$name" 2>/dev/null || true
  rm -f "$tmp_zip"
}

fetch_one "ffmpeg" "$PINNED_FFMPEG_SHA256" "${FFMPEG_SHA256:-}"
fetch_one "ffprobe" "$PINNED_FFPROBE_SHA256" "${FFPROBE_SHA256:-}"

printf '%s' "$VERSION_TAG" > "$VERSION_PATH"

echo "$VENDOR_DIR"
