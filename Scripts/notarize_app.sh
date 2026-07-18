#!/usr/bin/env bash
set -euo pipefail

# Notarizes and staples the packaged "DMonte Tool Box.app" so Gatekeeper opens it
# without warnings on other people's Macs. Run AFTER Scripts/package_app.sh has
# produced a Developer-ID + Hardened-Runtime signed app.
#
# Credentials come from the environment (never hard-coded — this repo is public).
# Provide ONE of:
#
#   A) App Store Connect API key (recommended for CI):
#        NOTARY_KEY_ID, NOTARY_KEY_ISSUER, NOTARY_KEY_PATH (path to AuthKey_*.p8)
#
#   B) Apple ID + app-specific password:
#        NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#
#   C) A pre-saved notarytool keychain profile:
#        NOTARY_PROFILE  (name passed to `xcrun notarytool ... --keychain-profile`)
#
# If none are set, this prints how to configure them and exits 0 WITHOUT failing,
# so `make_release_artifacts.sh` can run unnotarized for local/ad-hoc builds.
# EXCEPTION: in CI, when the packaged app carries a real Developer ID signature,
# missing notary credentials are a hard error — publishing a Developer-ID-signed
# but un-notarized app would get Gatekeeper-blocked on every downloader's Mac.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/DMonte Tool Box.app"

if [[ ! -d "$APP_DIR" ]]; then
  echo "error: $APP_DIR not found — run Scripts/package_app.sh first." >&2
  exit 1
fi

# Decide which auth mode we have.
NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_KEY_ISSUER:-}" && -n "${NOTARY_KEY_PATH:-}" ]]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_KEY_ISSUER")
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
  NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
else
  # In CI with a real Developer ID in play, skipping silently would publish a
  # signed-but-unnotarized app that Gatekeeper blocks for everyone — fail loudly
  # and name exactly which of the API-key vars is missing (names only, no values).
  #
  # Keyed on the signature the app ACTUALLY carries, not on CODESIGN_IDENTITY:
  # that variable is optional — package_app.sh also resolves a Developer ID
  # straight out of the keychain — so an env-var check would miss exactly the
  # cert-configured-but-notary-creds-missing case this exists to catch. An
  # ad-hoc signature reports "Signature=adhoc" and no Authority line.
  SIGNATURE_INFO="$(codesign --display --verbose=2 "$APP_DIR" 2>&1 || true)"
  if [[ ( -n "${GITHUB_ACTIONS:-}" || -n "${CI:-}" ) \
        && "$SIGNATURE_INFO" == *"Authority=Developer ID Application"* ]]; then
    MISSING=()
    [[ -z "${NOTARY_KEY_ID:-}" ]] && MISSING+=(NOTARY_KEY_ID)
    [[ -z "${NOTARY_KEY_ISSUER:-}" ]] && MISSING+=(NOTARY_KEY_ISSUER)
    [[ -z "${NOTARY_KEY_PATH:-}" ]] && MISSING+=("NOTARY_KEY_PATH (set from the NOTARY_KEY_P8 secret)")
    echo "::error::Notary credentials incomplete in CI — missing: ${MISSING[*]}." \
         "This build is signed with a real Developer ID, and a Developer-ID-signed" \
         "but un-notarized app must NOT be published — Gatekeeper would block it on" \
         "every downloader's machine. Fix the notary secrets (or unset the signing" \
         "secrets for an ad-hoc test build) and re-run." >&2
    exit 1
  fi

  cat >&2 <<'MSG'
Skipping notarization: no credentials in the environment.

To notarize, set ONE of these credential sets and re-run:
  • API key:   NOTARY_KEY_ID, NOTARY_KEY_ISSUER, NOTARY_KEY_PATH
  • Apple ID:  NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
  • Profile:   NOTARY_PROFILE  (see: xcrun notarytool store-credentials)
MSG
  exit 0
fi

# notarytool ingests a zip/dmg/pkg, not a bare .app — zip it for submission.
# The trap cleans the temp dir on every exit path, success and failure alike.
SUBMIT_TMP="$(mktemp -d)"
SUBMIT_ZIP="$SUBMIT_TMP/DMonteToolBox-notarize.zip"
trap 'rm -rf "$SUBMIT_TMP"' EXIT
echo "Zipping app for notarization…"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$SUBMIT_ZIP"

# Submit and check the RESULT, not just the exit code — `notarytool submit --wait`
# has historically exited 0 even when the submission status is "Invalid", which
# otherwise only surfaces later as a cryptic stapler failure with the actual
# rejection reasons never fetched.
echo "Submitting to Apple notary service (this can take a few minutes)…"
SUBMIT_EXIT=0
SUBMIT_JSON="$(xcrun notarytool submit "$SUBMIT_ZIP" "${NOTARY_ARGS[@]}" --wait --output-format json)" || SUBMIT_EXIT=$?
printf '%s\n' "$SUBMIT_JSON"

# python3 is already a dependency of make_release_artifacts.sh, so no new tools.
SUBMISSION_ID="$(printf '%s' "$SUBMIT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' 2>/dev/null || true)"
SUBMIT_STATUS="$(printf '%s' "$SUBMIT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' 2>/dev/null || true)"

if [[ "$SUBMIT_EXIT" -ne 0 || "$SUBMIT_STATUS" != "Accepted" ]]; then
  echo "error: notarization was not accepted (exit code $SUBMIT_EXIT, status: ${SUBMIT_STATUS:-unknown})." >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    # Pull Apple's rejection log so the reasons land in the build output.
    echo "Fetching notary log for submission $SUBMISSION_ID…" >&2
    xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" >&2 || true
  fi
  exit 1
fi

# Staple the ticket onto the .app so it validates offline / after the zip is gone.
echo "Stapling notarization ticket…"
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

# Final Gatekeeper assessment — what a downloader's Mac will actually evaluate.
echo "Gatekeeper assessment:"
spctl --assess --type execute --verbose=2 "$APP_DIR"

echo "Notarized and stapled: $APP_DIR"
