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

# Sign inside-out instead of using the deprecated `codesign --deep`: nested
# Sparkle components first (XPC services, helper apps, the framework itself),
# then the outer app bundle.
SPARKLE_APP_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
NESTED_TARGETS=(
  "$SPARKLE_APP_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
  "$SPARKLE_APP_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
  "$SPARKLE_APP_FRAMEWORK/Versions/B/Autoupdate"
  "$SPARKLE_APP_FRAMEWORK/Versions/B/Updater.app"
  "$SPARKLE_APP_FRAMEWORK"
)

if [[ "$IDENTITY" == "-" ]]; then
  # The explicit designated requirement stays stable across local rebuilds,
  # which is friendlier to TCC than a changing ad-hoc cdhash alone.
  for target in "${NESTED_TARGETS[@]}"; do
    [[ -e "$target" ]] || continue
    codesign --force --sign - "$target"
  done
  codesign --force --sign - \
    --requirements '=designated => identifier "app.meetingnotes.menu"' "$APP"
  echo "warning: ad-hoc signed; set MEETING_NOTES_CODE_SIGN_IDENTITY to an Apple Development identity for the most stable permissions" >&2
else
  for target in "${NESTED_TARGETS[@]}"; do
    [[ -e "$target" ]] || continue
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$target"
  done
  # Pin the designated requirement to the bundle id and *team* rather than the
  # default, which embeds the certificate's leaf common name. Development and
  # release builds are signed with different certificates from the same team,
  # so the default requirement flips between them and macOS treats every
  # switch as a brand-new app, throwing away all granted permissions (TCC).
  # Keying on the team keeps one privacy identity across both certificates.
  TEAM_ID=$(
    security find-certificate -c "$IDENTITY" -p \
      | openssl x509 -noout -subject -nameopt multiline \
      | awk '/organizationalUnitName/ { print $3; exit }'
  )
  if [[ ! "$TEAM_ID" =~ '^[A-Z0-9]{10}$' ]]; then
    echo "error: could not determine the team id for identity: $IDENTITY" >&2
    exit 6
  fi
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/Resources/Entitlements.plist" --sign "$IDENTITY" \
    --requirements "=designated => identifier \"app.meetingnotes.menu\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM_ID\"" \
    "$APP"
fi
echo "$APP"
