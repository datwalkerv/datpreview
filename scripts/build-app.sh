#!/bin/zsh
# Builds datpreview.app (release) into ./build and optionally installs it into /Applications.
#
#   scripts/build-app.sh              build ./build/datpreview.app for this Mac's architecture
#   scripts/build-app.sh --universal  build for Apple silicon and Intel (used for the DMG)
#   scripts/build-app.sh --install    also copy to /Applications and (re)launch it
#
# Signing: macOS ties Accessibility / Screen Recording grants to the code signature. Ad-hoc
# signatures change on every build, so you'd have to re-grant after each rebuild. To avoid that,
# create a self-signed "Code Signing" certificate in Keychain Access (Certificate Assistant →
# Create a Certificate…, type: Code Signing) and export its name:
#   export DATPREVIEW_SIGN_IDENTITY="datpreview Dev"
set -euo pipefail
cd "${0:A:h}/.."

APP=build/datpreview.app
VERSION=0.1.2

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ " $* " == *" --universal "* ]]; then
  slices=()
  for arch in arm64 x86_64; do
    triple="$arch-apple-macosx15.2"
    swift build -c release --product datpreview --triple "$triple"
    slices+=("$(swift build -c release --triple "$triple" --show-bin-path)/datpreview")
  done
  lipo -create "${slices[@]}" -output "$APP/Contents/MacOS/datpreview"
else
  swift build -c release --product datpreview
  cp "$(swift build -c release --show-bin-path)/datpreview" "$APP/Contents/MacOS/datpreview"
fi
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>world.dat.datpreview</string>
  <key>CFBundleName</key><string>datpreview</string>
  <key>CFBundleDisplayName</key><string>datpreview</string>
  <key>CFBundleExecutable</key><string>datpreview</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.2</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ -n "${DATPREVIEW_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --sign "$DATPREVIEW_SIGN_IDENTITY" "$APP"
else
  echo "note: ad-hoc signing; permissions must be re-granted after each rebuild (see header)." >&2
  codesign --force --sign - "$APP"
fi
echo "built $APP"

if [[ " $* " == *" --install "* ]]; then
  pkill -ix datpreview 2>/dev/null && sleep 1 || true
  rm -rf /Applications/datpreview.app
  cp -R "$APP" /Applications/
  open /Applications/datpreview.app
  echo "installed /Applications/datpreview.app"
fi
