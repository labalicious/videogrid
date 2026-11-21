#!/bin/zsh
# Builds "Video Grid.app" into ./build.
#   ./build.sh            build into build/app.noindex/
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
# The ".noindex" folder keeps Spotlight and Launchpad from listing this build copy
# next to the installed one.
APP="build/app.noindex/$NAME.app"
rm -rf "build/$NAME.app"                     # where older versions of this script put it

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

  # The disk image opens as a small window: the app, a pink arrow, and the Applications folder.
  # Finder lays the window out (it writes the .DS_Store), so the first run asks to let this
  # terminal control Finder.
  DMG="build/$NAME.dmg"
  STAGE="build/dmg"
  RW="build/$NAME-rw.dmg"
  rm -rf "$STAGE" "$DMG" "$RW"
  mkdir -p "$STAGE/.background"
  ditto "$APP" "$STAGE/$NAME.app"
  ln -s /Applications "$STAGE/Applications"
  cp Resources/dmg-background.tiff "$STAGE/.background/background.tiff"
  cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
  hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size 400m -ov "$RW"
  rm -rf "$STAGE"

  MNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
  [[ -d "$MNT" ]] || { echo "Couldn't mount $RW" >&2; exit 1; }
  SetFile -a C "$MNT"                         # use .VolumeIcon.icns as the disk's icon
  DISK="${MNT:t}"
  osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$DISK"
    open
    set w to container window
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set pathbar visible of w to false
    set bounds of w to {200, 120, 840, 548}
    set opts to icon view options of w
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$NAME.app" of w to {160, 190}
    set position of item "Applications" of w to {480, 190}
    -- Close and reopen so Finder saves the size; it otherwise widens the window.
    close
    open
    set bounds of container window to {200, 120, 840, 548}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
  chmod -Rf go-w "$MNT" || true
  rm -rf "$MNT/.fseventsd" "$MNT/.Trashes"
  sync
  hdiutil detach -quiet "$MNT" || { sleep 2; hdiutil detach -force -quiet "$MNT"; }
  hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
  rm -f "$RW"
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
