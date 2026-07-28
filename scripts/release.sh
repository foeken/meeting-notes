#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
CHANNEL=stable
if [[ "${1:-}" == "--beta" ]]; then
  CHANNEL=beta
  shift
elif [[ "${1:-}" == "--stable" ]]; then
  shift
fi
VERSION=${1:?usage: scripts/release.sh [--beta] VERSION BUILD [RELEASE_NOTES_FILE]}
BUILD=${2:?usage: scripts/release.sh [--beta] VERSION BUILD [RELEASE_NOTES_FILE]}
NOTES_FILE=${3:-}
RELEASE_REPO=${MEETING_NOTES_RELEASE_REPO:-foeken/meeting-notes}
NOTARY_PROFILE=${MEETING_NOTES_NOTARY_PROFILE:?set MEETING_NOTES_NOTARY_PROFILE to a notarytool Keychain profile}
IDENTITY=${MEETING_NOTES_CODE_SIGN_IDENTITY:-}
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
APP="$ROOT/Meeting Notes.app"
ARCHIVE_NAME="MeetingNotes-$VERSION.dmg"
WORK=$(mktemp -d)
PLIST_COMMITTED=0
cleanup() {
  rm -rf "$WORK"
  # A failed release must not leave the version bump behind: a dirty
  # Resources/Info.plist blocks the clean-checkout guard on the next attempt.
  if [[ "$PLIST_COMMITTED" != 1 ]]; then
    git -C "$ROOT" checkout --quiet -- Resources/Info.plist 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "error: release from a clean checkout so version and appcast commits stay isolated" >&2
  exit 2
fi

# A beta may carry a prerelease suffix (1.2.0-beta.1) so it can ship ahead of
# the stable version it becomes. The build number stays a plain integer for
# both channels, because Sparkle orders updates by it.
if [[ "$CHANNEL" == beta ]]; then
  VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'
else
  VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'
fi
if ! [[ "$VERSION" =~ $VERSION_PATTERN && "$BUILD" =~ '^[0-9]+$' ]]; then
  echo "error: VERSION must be x.y.z${CHANNEL:+ (x.y.z-beta.N is allowed for --beta)} and BUILD must be an integer" >&2
  exit 2
fi
if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
  echo "error: release notes file does not exist: $NOTES_FILE" >&2
  exit 2
fi
for tool in generate_appcast generate_keys; do
  if [[ ! -x "$SPARKLE_BIN/$tool" ]]; then
    echo "error: missing Sparkle tool $SPARKLE_BIN/$tool; run swift package resolve" >&2
    exit 3
  fi
done
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(
    security find-identity -v -p codesigning \
      | awk -F'"' '/Developer ID Application:/ { print $2; exit }'
  )
fi
if [[ -z "$IDENTITY" ]] || ! security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
  echo "error: Developer ID signing identity is unavailable: $IDENTITY" >&2
  exit 4
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "error: GitHub CLI authentication is unavailable; run gh auth login" >&2
  exit 5
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$ROOT/Resources/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$ROOT/Resources/Info.plist"

export MEETING_NOTES_CODE_SIGN_IDENTITY="$IDENTITY"
"$ROOT/scripts/build-app.sh"
codesign --verify --deep --strict --verbose=2 "$APP"

/usr/bin/ditto -c -k --keepParent "$APP" "$WORK/MeetingNotes-notarize.zip"
xcrun notarytool submit "$WORK/MeetingNotes-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

mkdir -p "$WORK/dmg-root"
cp -R "$APP" "$WORK/dmg-root/"
ln -sf /Applications "$WORK/dmg-root/Applications"
hdiutil create -volname "Meeting Notes" \
  -srcfolder "$WORK/dmg-root" \
  -ov -format UDZO \
  "$WORK/$ARCHIVE_NAME"
xcrun notarytool submit "$WORK/$ARCHIVE_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$WORK/$ARCHIVE_NAME"

mkdir -p "$WORK/appcast-source"
cp "$WORK/$ARCHIVE_NAME" "$WORK/appcast-source/$ARCHIVE_NAME"
if [[ -n "$NOTES_FILE" ]]; then
  cp "$NOTES_FILE" "$WORK/appcast-source/MeetingNotes-$VERSION.md"
fi

# Two feeds are published:
#
#   appcast.xml       stable only, read by every default installation
#   appcast-beta.xml  betas *and* stable, read by Macs set to the beta channel
#
# A stable release is written to both feeds, so a beta tester keeps receiving
# stable releases instead of being stranded on an ageing test build. Beta
# entries are additionally tagged with <sparkle:channel>beta</sparkle:channel>,
# so a stable updater ignores them even if it ever read this feed.
generate_feed() {
  local output="$1"
  shift
  "$SPARKLE_BIN/generate_appcast" \
    --account meeting-notes-menu \
    --download-url-prefix "https://github.com/$RELEASE_REPO/releases/download/v$VERSION/" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    --embed-release-notes \
    "$@" \
    -o "$output" \
    "$WORK/appcast-source"
}

if [[ "$CHANNEL" == beta ]]; then
  generate_feed "$ROOT/appcast-beta.xml" --channel "beta"
else
  generate_feed "$ROOT/appcast.xml"
  generate_feed "$ROOT/appcast-beta.xml"
fi

git -C "$ROOT" add Resources/Info.plist appcast.xml appcast-beta.xml
if ! git -C "$ROOT" diff --cached --quiet; then
  git -C "$ROOT" commit -m "Publish Meeting Notes $VERSION ($CHANNEL)"
  git -C "$ROOT" push origin main
fi
PLIST_COMMITTED=1
PUBLISHED_SHA=$(git -C "$ROOT" rev-parse HEAD)

RELEASE_ARGS=(
  "v$VERSION" "$WORK/$ARCHIVE_NAME"
  --repo "$RELEASE_REPO"
  --target "$PUBLISHED_SHA"
  --title "Meeting Notes $VERSION"
)
if [[ "$CHANNEL" == beta ]]; then
  RELEASE_ARGS+=(--prerelease)
fi
if [[ -n "$NOTES_FILE" ]]; then
  RELEASE_ARGS+=(--notes-file "$NOTES_FILE")
else
  RELEASE_ARGS+=(--notes "Automatic updates for Meeting Notes $VERSION.")
fi
if gh release view "v$VERSION" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$WORK/$ARCHIVE_NAME" --repo "$RELEASE_REPO" --clobber
else
  gh release create $RELEASE_ARGS
fi

echo "Published Meeting Notes $VERSION ($BUILD, $CHANNEL) to https://github.com/$RELEASE_REPO/releases/tag/v$VERSION"
