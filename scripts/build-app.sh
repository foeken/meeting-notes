#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
APP="$ROOT/Meeting Notes.app"
ARCH=$(uname -m)

swift build --package-path "$ROOT" -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$ROOT/.build/$ARCH-apple-macosx/release/MeetingNotes" "$APP/Contents/MacOS/MeetingNotes"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/MeetingNotes"
SPARKLE_FRAMEWORK=$(find "$ROOT/.build/artifacts" -path '*/Sparkle.framework' -type d -print -quit)
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  echo "error: Sparkle.framework was not resolved by Swift Package Manager" >&2
  exit 5
fi
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/CodexLogo.svg" "$APP/Contents/Resources/CodexLogo.svg"
IDENTITY=${MEETING_NOTES_CODE_SIGN_IDENTITY:--}
if [[ "$IDENTITY" == "-" ]]; then
  # The explicit designated requirement stays stable across local rebuilds,
  # which is friendlier to TCC than a changing ad-hoc cdhash alone.
  codesign --force --deep --sign - \
    --requirements '=designated => identifier "app.meetingnotes.menu"' "$APP"
  echo "warning: ad-hoc signed; set MEETING_NOTES_CODE_SIGN_IDENTITY to an Apple Development identity for the most stable permissions" >&2
else
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$ROOT/Resources/Entitlements.plist" --sign "$IDENTITY" "$APP"
fi
echo "$APP"
