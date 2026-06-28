#!/usr/bin/env bash
#
# release-notarize.sh — distribution pipeline (Developer ID + notarization).
#
# Builds a Release archive signed with Developer ID + Hardened Runtime, submits it to
# Apple's notary service, staples the ticket, and verifies the result. Produces a
# distributable zip under build/distrib/.
#
# Prerequisites (one-time, already on this machine):
#   - "Developer ID Application" certificate in the login keychain
#   - notarytool keychain profile:  xcrun notarytool store-credentials "$NOTARY_PROFILE" ...
#
# Day-to-day Debug/Release builds stay ad-hoc signed (no cert needed) — Developer ID is
# injected here via xcodebuild overrides only, so contributor builds are unaffected.
#
# Usage:
#   ./Scripts/release-notarize.sh                # full pipeline
#   SKIP_NOTARIZE=1 ./Scripts/release-notarize.sh  # signed archive + verify only
#
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:?set TEAM_ID to your Apple Developer Team ID (see docs/DISTRIBUTION.md)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-clipysi-notary}"
DISTRIB_DIR="build/distrib"
ARCHIVE_PATH="$DISTRIB_DIR/ClipySi.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/ClipySi.app"

rm -rf "$DISTRIB_DIR"
mkdir -p "$DISTRIB_DIR"

echo "==> Archiving (Release, Developer ID, Hardened Runtime, universal)"
set -o pipefail && xcodebuild \
  -project Clipy.xcodeproj \
  -scheme Clipy \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -skipMacroValidation \
  archive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  | xcbeautify

echo "==> Re-signing Sparkle nested components (Developer ID + Hardened Runtime + timestamp)"
# The prebuilt Sparkle.framework ships with the Sparkle project's signature; xcodebuild's
# identity override does not re-sign nested executables, and notarization rejects them
# (no Developer ID, no secure timestamp). Re-sign innermost → outermost, then the app so
# its seal over Frameworks/ is valid again. Downloader.xpc is sandboxed — keep its
# entitlements. https://sparkle-project.org/documentation/sandboxing/#code-signing
SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force --options runtime --timestamp --sign "Developer ID Application" "$@"; }
sign --preserve-metadata=entitlements "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
sign "$SPARKLE_FW/Versions/B/Autoupdate"
sign "$SPARKLE_FW/Versions/B/Updater.app"
sign "$SPARKLE_FW"
sign "$APP_PATH"

echo "==> Verifying architectures (must be universal)"
BINARY="$APP_PATH/Contents/MacOS/ClipySi"
lipo -archs "$BINARY"
lipo -archs "$BINARY" | grep -q "x86_64" || { echo "ERROR: missing x86_64 slice"; exit 1; }
lipo -archs "$BINARY" | grep -q "arm64" || { echo "ERROR: missing arm64 slice"; exit 1; }

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=2 "$APP_PATH" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime" \
  || { echo "ERROR: not Developer ID signed with Hardened Runtime"; exit 1; }

VERSION=$(defaults read "$(pwd)/$APP_PATH/Contents/Info" CFBundleShortVersionString)
ZIP_PATH="$DISTRIB_DIR/ClipySi-$VERSION.zip"

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "==> SKIP_NOTARIZE=1 — stopping before submission. App: $APP_PATH"
  exit 0
fi

echo "==> Submitting for notarization (profile: $NOTARY_PROFILE)"
ditto -c -k --keepParent "$APP_PATH" "$DISTRIB_DIR/ClipySi-notarize-upload.zip"
xcrun notarytool submit "$DISTRIB_DIR/ClipySi-notarize-upload.zip" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format plist > "$DISTRIB_DIR/notarize-result.plist" \
  || { echo "ERROR: notarization submit failed"; cat "$DISTRIB_DIR/notarize-result.plist" 2>/dev/null; exit 1; }

STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$DISTRIB_DIR/notarize-result.plist")
SUBMISSION_ID=$(/usr/libexec/PlistBuddy -c "Print :id" "$DISTRIB_DIR/notarize-result.plist")
echo "==> Notarization status: $STATUS (id: $SUBMISSION_ID)"
if [[ "$STATUS" != "Accepted" ]]; then
  echo "ERROR: notarization not accepted — fetching log:"
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE"
  exit 1
fi

echo "==> Stapling ticket"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP_PATH"

echo "==> Packaging distributable zip"
rm -f "$DISTRIB_DIR/ClipySi-notarize-upload.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> DONE"
echo "    App:  $APP_PATH"
echo "    Zip:  $ZIP_PATH"
echo "    Next: sign_update + generate_appcast against this zip when cutting a release."
