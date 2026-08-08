#!/bin/bash
#
# Builds a Developer ID-signed, notarised, stapled Transcriber.dmg.
#
#   Scripts/release.sh                 # full run: archive → export → notarise → DMG
#   Scripts/release.sh --no-notarize   # everything except the two Apple round-trips
#
# One-time setup — store the notarisation credentials in the keychain, using an
# App Store Connect API key (Users and Access ▸ Integrations ▸ Team Keys, role
# "Developer" or above; the .p8 downloads exactly once):
#
#   xcrun notarytool store-credentials Transcriber \
#     --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
#     --key-id <KEYID> --issuer <ISSUER-UUID>
#
# or, with an Apple ID and an app-specific password:
#
#   xcrun notarytool store-credentials Transcriber \
#     --apple-id you@example.com --team-id MCGN49R93E --password <app-specific-password>
#
# Either way the secret ends up in the keychain, so the .p8 is only needed once
# (keep it somewhere outside the repo — *.p8 is gitignored, but don't rely on it).
# Override the profile name with NOTARY_PROFILE if you called it something else.
#
# The app is notarised *and* the DMG is notarised. Stapling the app itself is
# what lets a copy dragged out of the DMG launch with no network — which matters
# for an app whose whole promise is that it works offline.

set -euo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCHEME="Transcriber"
readonly APP_NAME="Transcriber"
readonly TEAM_ID="MCGN49R93E"
readonly NOTARY_PROFILE="${NOTARY_PROFILE:-Transcriber}"

readonly DIST_DIR="$PROJECT_ROOT/dist"
readonly ARCHIVE_PATH="$DIST_DIR/$APP_NAME.xcarchive"
readonly EXPORT_DIR="$DIST_DIR/export"
readonly APP_PATH="$EXPORT_DIR/$APP_NAME.app"

NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

cd "$PROJECT_ROOT"

# ---------------------------------------------------------------- preflight --

step "Preflight"
IDENTITIES=$(security find-identity -v -p codesigning)
grep -q "Developer ID Application" <<<"$IDENTITIES" \
  || fail "no \"Developer ID Application\" certificate in the keychain"

if (( NOTARIZE )); then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "no notarytool keychain profile named \"$NOTARY_PROFILE\" (see the header of this script)"
fi

VERSION=$(xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$SCHEME" \
  -configuration Release -showBuildSettings 2>/dev/null \
  | awk '/ MARKETING_VERSION =/ { print $3; exit }')
BUILD=$(xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$SCHEME" \
  -configuration Release -showBuildSettings 2>/dev/null \
  | awk '/ CURRENT_PROJECT_VERSION =/ { print $3; exit }')
[[ -n "$VERSION" ]] || fail "could not read MARKETING_VERSION"
echo "Transcriber $VERSION ($BUILD)"

readonly DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"

# ------------------------------------------------------------------ archive --

step "Archiving (Release)"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  | tail -5

step "Exporting with Developer ID"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist Config/ExportOptions.plist \
  | tail -5
[[ -d "$APP_PATH" ]] || fail "export produced no app at $APP_PATH"

# -------------------------------------------------------------------- verify --

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Captured rather than piped straight into grep: `grep -q` exits on its first
# match, codesign takes SIGPIPE, and `pipefail` would report that as a failure.
SIGNING_INFO=$(codesign --display --verbose=4 "$APP_PATH" 2>&1)
ENTITLEMENTS=$(codesign --display --entitlements - --xml "$APP_PATH" 2>/dev/null)

grep -E 'Authority|flags' <<<"$SIGNING_INFO" || true

grep -q 'Authority=Developer ID Application' <<<"$SIGNING_INFO" \
  || fail "the exported app is not signed with a Developer ID Application certificate"
# A Hardened Runtime build reports flags including `runtime`.
grep -q 'flags=.*runtime' <<<"$SIGNING_INFO" \
  || fail "Hardened Runtime is not enabled on the exported app"
grep -q 'com.apple.security.device.audio-input' <<<"$ENTITLEMENTS" \
  || fail "audio-input entitlement missing — the microphone would be denied silently"
# Debug builds get this automatically; shipping one would let any process
# attach to the app and read whatever has been dictated.
if grep -q 'com.apple.security.get-task-allow' <<<"$ENTITLEMENTS"; then
  fail "get-task-allow is present — this is a debug-signed build, do not ship it"
fi
echo "Developer ID, Hardened Runtime on, audio-input entitlement present."

# ------------------------------------------------------------- notarise app --

if (( NOTARIZE )); then
  step "Notarising the app"
  ZIP_PATH="$DIST_DIR/$APP_NAME-app.zip"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
  xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$ZIP_PATH"

  step "Stapling the app"
  xcrun stapler staple "$APP_PATH"
fi

# ------------------------------------------------------------------ package --

step "Building the DMG"
STAGE_DIR="$DIST_DIR/dmg"
mkdir -p "$STAGE_DIR"
ditto "$APP_PATH" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE_DIR" \
  -ov -format UDZO \
  "$DMG_PATH" >/dev/null
rm -rf "$STAGE_DIR"

if (( NOTARIZE )); then
  step "Notarising the DMG"
  codesign --sign "Developer ID Application" --timestamp "$DMG_PATH"
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" --wait

  step "Stapling the DMG"
  xcrun stapler staple "$DMG_PATH"

  step "Gatekeeper assessment"
  # What a first-time user's Mac will conclude about the app.
  spctl --assess --type execute --verbose=2 "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

step "Done"
echo "$DMG_PATH"
ls -lh "$DMG_PATH" | awk '{ print $5 }'
if (( ! NOTARIZE )); then
  echo
  echo "NOT notarised — this DMG is for local testing only."
fi
