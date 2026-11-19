#!/bin/zsh
# Builds "Video Grid.app" into ./build.
#   ./build.sh            build
#   ./build.sh install    build, then copy to ~/Applications
#   ./build.sh dist       build, sign with your Developer ID, notarize, and make build/Video Grid.dmg
#
# Needs: Xcode Command Line Tools (swiftc) and VLC.app in /Applications.
# libVLC (lib/, plugins/, share/) is copied from VLC.app into the bundle, so later
# VLC updates don't affect Video Grid. Re-run this after updating VLC to pick up fixes.
#
# dist also needs (one-time setup, see README):
#   - a "Developer ID Application" certificate in your keychain (or SIGN_ID="…" to pick one;
#     SIGN_ID=- signs ad hoc, for testing the signing step only)
#   - notarization credentials saved with:
#       xcrun notarytool store-credentials videogrid-notary --apple-id YOU --team-id TEAMID
#     (NOTARY_PROFILE=… to use another name; NOTARIZE=0 to skip notarizing)
set -euo pipefail
cd "${0:A:h}"

NAME="Video Grid"
EXE="VideoGrid"
VLC_APP="${VLC_APP:-/Applications/VLC.app}"
VLC_DIR="$VLC_APP/Contents/MacOS"
APP="build/$NAME.app"

[[ -f "$VLC_DIR/lib/libvlc.dylib" ]] || { echo "VLC.app not found at $VLC_APP" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O -swift-version 5 ${DEBUG:+-DVLCGRID_DEBUG} -target arm64-apple-macos14.0 \
  -import-objc-header Sources/Bridging.h \
  -I "$VLC_DIR/include" \
  -L "$VLC_DIR/lib" -lvlc \
  -Xlinker -rpath -Xlinker @executable_path/lib \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$EXE"

echo "Bundling libVLC from $VLC_APP…"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto "$VLC_DIR/lib" "$APP/Contents/MacOS/lib"
ditto "$VLC_DIR/plugins" "$APP/Contents/MacOS/plugins"
ditto "$VLC_DIR/share" "$APP/Contents/MacOS/share"

echo "Built: $PWD/$APP"

case "${1:-}" in
install)
  mkdir -p ~/Applications
  rm -rf ~/Applications/"$NAME.app"
  ditto "$APP" ~/Applications/"$NAME.app"
  echo "Installed: ~/Applications/$NAME.app"
  ;;

dist)
  IDENTITY="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
  if [[ -z "$IDENTITY" ]]; then
    echo "No \"Developer ID Application\" certificate in your keychain." >&2
    echo "Create one at developer.apple.com → Certificates, install it, then re-run." >&2
    exit 1
  fi
  echo "Signing with: $IDENTITY"
  TS=(--timestamp); [[ "$IDENTITY" == "-" ]] && TS=(--timestamp=none)
  # Sign the inside first: every libVLC library and plugin, then the app itself.
  find "$APP/Contents/MacOS/lib" "$APP/Contents/MacOS/plugins" -name '*.dylib' -print0 |
    xargs -0 -n 50 codesign --force "${TS[@]}" --options runtime --sign "$IDENTITY"
  codesign --force "${TS[@]}" --options runtime --entitlements Resources/VideoGrid.entitlements \
    --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
  echo "Signature OK"

  DMG="build/$NAME.dmg"
  STAGE="build/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/$NAME.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
  codesign --force "${TS[@]}" --sign "$IDENTITY" "$DMG"

  if [[ "$IDENTITY" == "-" || "${NOTARIZE:-1}" == "0" ]]; then
    echo "Skipped notarization. Disk image: $PWD/$DMG"
    exit 0
  fi
  echo "Notarizing (usually a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "${NOTARY_PROFILE:-videogrid-notary}" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  echo "Ready to share: $PWD/$DMG"
  ;;
esac
