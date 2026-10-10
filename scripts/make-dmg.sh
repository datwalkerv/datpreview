#!/bin/zsh
# Builds a universal datpreview.app and packages it as build/datpreview-<version>.dmg
# (app + Applications shortcut, drag to install).
#
# Without an Apple Developer ID the app is ad-hoc signed, and macOS will block the first launch of
# a downloaded copy until the user allows it in System Settings → Privacy & Security.
# With one, set both of these to produce a signed, notarized and stapled DMG:
#   export DATPREVIEW_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   export DATPREVIEW_NOTARY_PROFILE="datpreview"   # xcrun notarytool store-credentials datpreview …
set -euo pipefail
cd "${0:A:h}/.."

scripts/build-app.sh --universal

APP=build/datpreview.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/datpreview-$VERSION.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "datpreview" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [[ -n "${DATPREVIEW_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$DATPREVIEW_SIGN_IDENTITY" "$DMG"
fi
if [[ -n "${DATPREVIEW_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$DATPREVIEW_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "built $DMG ($(du -h "$DMG" | cut -f1))"
