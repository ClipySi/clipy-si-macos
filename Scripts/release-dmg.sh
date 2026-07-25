#!/usr/bin/env bash
#
# release-dmg.sh — package the notarized app into the distributable disk image.
#
# Second half of the distribution pipeline: `release-notarize.sh` produces a notarized,
# stapled ClipySi.app inside build/distrib/ClipySi.xcarchive; this wraps it in a DMG,
# signs and notarizes the image itself, staples it, and verifies it the way a downloaded
# image is assessed. The DMG (not the zip) is what the GitHub Release ships and what the
# Sparkle appcast's enclosure points at.
#
# The image itself is notarized separately from the app it contains: Gatekeeper evaluates
# the disk image a user downloads, so an unnotarized image would be blocked even though
# the app inside is fine.
#
# Prerequisites (same as release-notarize.sh):
#   - "Developer ID Application" certificate in the login keychain
#   - notarytool keychain profile:  xcrun notarytool store-credentials "$NOTARY_PROFILE" ...
#
# Usage:
#   ./Scripts/release-notarize.sh && ./Scripts/release-dmg.sh   # full release build
#   SKIP_NOTARIZE=1 ./Scripts/release-dmg.sh                    # build + sign the image only
#
# Next, to cut the release: sign the DMG into the appcast with Sparkle's `generate_appcast`,
# then publish the DMG + appcast.xml (+ any generated .delta) as GitHub Release assets.
#
set -euo pipefail

cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-clipysi-notary}"
DISTRIB_DIR="build/distrib"
APP_PATH="$DISTRIB_DIR/ClipySi.xcarchive/Products/Applications/ClipySi.app"
STAGE_DIR="$DISTRIB_DIR/dmg-stage"

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: $APP_PATH not found — run ./Scripts/release-notarize.sh first"
  exit 1
fi

echo "==> Verifying the app is notarized and stapled"
# A DMG built around an unstapled app would still install, but the app could not launch
# offline on a machine that has never seen its notarization ticket.
xcrun stapler validate "$APP_PATH"

VERSION=$(defaults read "$(pwd)/$APP_PATH/Contents/Info" CFBundleShortVersionString)
BUILD=$(defaults read "$(pwd)/$APP_PATH/Contents/Info" CFBundleVersion)
DMG_PATH="$DISTRIB_DIR/ClipySi-$VERSION.dmg"
echo "    ClipySi $VERSION (build $BUILD)"

echo "==> Staging the image contents (app + /Applications symlink)"
rm -rf "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$STAGE_DIR"
ditto "$APP_PATH" "$STAGE_DIR/ClipySi.app"   # ditto preserves the stapled ticket + signature
ln -s /Applications "$STAGE_DIR/Applications"

echo "==> Creating the disk image (UDZO)"
hdiutil create -volname "ClipySi $VERSION" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGE_DIR"

echo "==> Signing the disk image"
codesign --force --timestamp --sign "Developer ID Application" "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "==> SKIP_NOTARIZE=1 — stopping before submission. Image: $DMG_PATH"
  exit 0
fi

echo "==> Submitting the image for notarization (profile: $NOTARY_PROFILE)"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format plist > "$DISTRIB_DIR/notarize-dmg-result.plist" \
  || { echo "ERROR: notarization submit failed"; cat "$DISTRIB_DIR/notarize-dmg-result.plist" 2>/dev/null; exit 1; }

STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$DISTRIB_DIR/notarize-dmg-result.plist")
SUBMISSION_ID=$(/usr/libexec/PlistBuddy -c "Print :id" "$DISTRIB_DIR/notarize-dmg-result.plist")
echo "==> Notarization status: $STATUS (id: $SUBMISSION_ID)"
if [[ "$STATUS" != "Accepted" ]]; then
  echo "ERROR: notarization not accepted — fetching log:"
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE"
  exit 1
fi

echo "==> Stapling the image"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "==> Gatekeeper assessment (as a downloaded disk image)"
# `--type open --context context:primary-signature` is how Gatekeeper evaluates a downloaded
# image; `--type execute` (the app check) does not apply to a DMG.
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

echo "==> DONE"
echo "    Image: $DMG_PATH ($(stat -f%z "$DMG_PATH") bytes)"
echo "    Next:  generate_appcast over a directory holding this DMG + the previous appcast.xml,"
echo "           then publish the DMG, appcast.xml and any .delta as GitHub Release assets."
