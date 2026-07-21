#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION_OVERRIDE:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"
TAG_NAME="${TAG_NAME:-v$VERSION}"
REPOSITORY="${GITHUB_REPOSITORY:-havokentity/MacTools}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-com.havokentity.mactools}"
SPARKLE_SIGN_UPDATE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"
ZIP_NAME="DMonte-Tool-Box-$VERSION.zip"
ZIP_PATH="$ROOT_DIR/dist/$ZIP_NAME"
APPCAST_PATH="$ROOT_DIR/dist/appcast.xml"
RELEASE_NOTES_PATH="$ROOT_DIR/dist/release-notes.md"
DOWNLOAD_URL="https://github.com/$REPOSITORY/releases/download/$TAG_NAME/$ZIP_NAME"

github_release_notes() {
  [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]] || return 1

  GITHUB_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}" \
  REPOSITORY="$REPOSITORY" \
  TAG_NAME="$TAG_NAME" \
  python3 <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

token = os.environ["GITHUB_TOKEN"]
repository = os.environ["REPOSITORY"]
tag_name = os.environ["TAG_NAME"]
url = f"https://api.github.com/repos/{repository}/releases/tags/{tag_name}"
request = urllib.request.Request(
    url,
    headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "User-Agent": "dmonte-release-script",
    },
)

try:
    with urllib.request.urlopen(request, timeout=10) as response:
        body = json.load(response).get("body") or ""
except (OSError, urllib.error.HTTPError, urllib.error.URLError):
    sys.exit(1)

body = body.strip()
if not body:
    sys.exit(1)

print(body)
PY
}

changelog_release_notes() {
  VERSION="$VERSION" ROOT_DIR="$ROOT_DIR" python3 <<'PY'
import os
import re
import sys
from pathlib import Path

version = os.environ["VERSION"]
changelog = Path(os.environ["ROOT_DIR"]) / "CHANGELOG.md"
if not changelog.exists():
    sys.exit(1)

text = changelog.read_text(encoding="utf-8")
pattern = re.compile(
    rf"^##\s+\[{re.escape(version)}\].*?\n(?P<body>.*?)(?=^##\s+\[|\Z)",
    re.MULTILINE | re.DOTALL,
)
match = pattern.search(text)
if not match:
    sys.exit(1)

body = match.group("body").strip()
if not body:
    sys.exit(1)

# Sparkle sizes its update window to the notes it is handed, and a full changelog
# section is tall enough to push the Update button off the bottom of the screen
# where it cannot be clicked. Prefer a curated Packaging/ReleaseNotes/<version>.md
# (RELEASE_NOTES_FILE, which wins over this); this cap is the safety net for a
# release that ships without one. Cut at a bullet or heading so the notes never
# end mid-sentence.
MAX_LINES = 40
lines = body.splitlines()
if len(lines) > MAX_LINES:
    cut = MAX_LINES
    while cut > 0 and not lines[cut].startswith(("- ", "#")):
        cut -= 1
    if cut == 0:
        cut = MAX_LINES
    body = "\n".join(lines[:cut]).rstrip()
    body += "\n\n[Full changelog](https://github.com/havokentity/MacTools/blob/main/CHANGELOG.md)"

print(body)
PY
}

xml_escape() {
  python3 -c '
import html
import sys

print(html.escape(sys.stdin.read(), quote=False), end="")
'
}

resolve_release_notes() {
  if [[ -n "${RELEASE_NOTES_FILE:-}" && -s "$RELEASE_NOTES_FILE" ]]; then
    sed '/./,$!d' "$RELEASE_NOTES_FILE"
    return 0
  fi

  if [[ -n "${RELEASE_NOTES:-}" ]]; then
    printf '%s\n' "$RELEASE_NOTES"
    return 0
  fi

  github_release_notes && return 0
  changelog_release_notes && return 0

  printf "D'Monte's Tool Box %s release.\n" "$VERSION"
}

"$ROOT_DIR/Scripts/package_app.sh"

# Notarize + staple BEFORE zipping, so the Sparkle archive ships a stapled app
# that Gatekeeper opens cleanly offline. notarize_app.sh no-ops (exit 0) when no
# notary credentials are present, so local/CI-without-secrets builds still work.
# Invoked via `bash` so a missing executable bit can never block the pipeline.
bash "$ROOT_DIR/Scripts/notarize_app.sh"

rm -f "$ZIP_PATH" "$APPCAST_PATH"
cd "$ROOT_DIR/dist"
ditto -c -k --sequesterRsrc --keepParent "DMonte Tool Box.app" "$ZIP_NAME"

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  signature_output="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_SIGN_UPDATE" --ed-key-file - "$ZIP_PATH")"
else
  signature_output="$("$SPARKLE_SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$ZIP_PATH")"
fi

ed_signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$signature_output")"
archive_length="$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<< "$signature_output")"
pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')"
release_notes="$(resolve_release_notes)"
release_notes_xml="$(printf '%s' "$release_notes" | xml_escape)"
printf '%s\n' "$release_notes" > "$RELEASE_NOTES_PATH"

if [[ -z "$ed_signature" || -z "$archive_length" ]]; then
  echo "Could not parse Sparkle signature output: $signature_output" >&2
  exit 1
fi

cat > "$APPCAST_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>D'Monte's Tool Box Updates</title>
    <link>https://github.com/$REPOSITORY</link>
    <description>Release feed for D'Monte's Tool Box.</description>
    <language>en</language>
    <item>
      <title>D'Monte's Tool Box $VERSION</title>
      <link>https://github.com/$REPOSITORY/releases/tag/$TAG_NAME</link>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <description sparkle:format="markdown">$release_notes_xml</description>
      <pubDate>$pub_date</pubDate>
      <enclosure
        url="$DOWNLOAD_URL"
        sparkle:edSignature="$ed_signature"
        length="$archive_length"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
XML

echo "Created $ZIP_PATH"
echo "Created $APPCAST_PATH"
