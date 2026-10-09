#!/bin/bash
# Builds a Release NitPicker.app and packs it into a disk image.
#
#   scripts/make-dmg.sh                                   # signed with whatever Xcode signs with: for trying it, not for sharing
#   scripts/make-dmg.sh --identity "Developer ID Application: Name (TEAMID)" --team TEAMID
#   scripts/make-dmg.sh --identity "..." --team TEAMID --notary-profile nitpicker-notary
#
# --notary-profile is a keychain profile made once with
#   xcrun notarytool store-credentials nitpicker-notary --apple-id <id> --team-id <TEAMID> --password <app-specific password>
# With it the app and then the disk image are submitted to Apple, waited for and stapled, so both open on any Mac without a warning.
# The output is build/NitPicker-<version>.dmg (build/ is not committed).
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="" TEAM="" PROFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) IDENTITY="$2"; shift 2 ;;
    --team) TEAM="$2"; shift 2 ;;
    --notary-profile) PROFILE="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
if [[ -n "$PROFILE" && -z "$IDENTITY" ]]; then echo "--notary-profile needs --identity (a Developer ID Application certificate)" >&2; exit 2; fi

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
DERIVED=build/DerivedData
APP="$DERIVED/Build/Products/Release/NitPicker.app"
DMG="build/NitPicker-$VERSION.dmg"
STAGING=build/dmg-staging

xcodegen generate
SIGNING=()
if [[ -n "$IDENTITY" ]]; then
  SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$IDENTITY" "DEVELOPMENT_TEAM=$TEAM" "OTHER_CODE_SIGN_FLAGS=--timestamp" ENABLE_HARDENED_RUNTIME=YES)
fi
xcodebuild -scheme NitPicker -configuration Release -destination 'platform=macOS' -derivedDataPath "$DERIVED" ${SIGNING[@]+"${SIGNING[@]}"} build

codesign --verify --deep --strict --verbose=2 "$APP"
echo "Signature:"; codesign -dv "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|flags' || true

if [[ -n "$PROFILE" ]]; then
  # Notarize and staple the app itself too, so a copy dragged out of the disk image passes Gatekeeper offline.
  ZIP=build/NitPicker-notarize.zip
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Nit Picker" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

if [[ -n "$IDENTITY" ]]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
fi
if [[ -n "$PROFILE" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
echo "Done: $DMG ($(du -h "$DMG" | cut -f1))"
