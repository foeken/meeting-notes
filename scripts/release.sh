#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
VERSION=${1:?usage: scripts/release.sh VERSION BUILD [RELEASE_NOTES_FILE]}
BUILD=${2:?usage: scripts/release.sh VERSION BUILD [RELEASE_NOTES_FILE]}
NOTES_FILE=${3:-}
RELEASE_REPO=${MEETING_NOTES_RELEASE_REPO:-foeken/meeting-notes-menu}
NOTARY_PROFILE=${MEETING_NOTES_NOTARY_PROFILE:?set MEETING_NOTES_NOTARY_PROFILE to a notarytool Keychain profile}
IDENTITY=${MEETING_NOTES_CODE_SIGN_IDENTITY:-}
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
APP="$ROOT/MeetingNotesMenu.app"
ARCHIVE_NAME="MeetingNotes-$VERSION.zip"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "error: release from a clean checkout so version and appcast commits stay isolated" >&2
  exit 2
fi

if ! [[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$BUILD" =~ '^[0-9]+$' ]]; then
  echo "error: VERSION must be x.y.z and BUILD must be an integer" >&2
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

/usr/bin/ditto -c -k --keepParent "$APP" "$WORK/$ARCHIVE_NAME"
xcrun notarytool submit "$WORK/$ARCHIVE_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
/usr/bin/ditto -c -k --keepParent "$APP" "$WORK/$ARCHIVE_NAME"

mkdir -p "$WORK/appcast-source"
cp "$WORK/$ARCHIVE_NAME" "$WORK/appcast-source/$ARCHIVE_NAME"
if [[ -n "$NOTES_FILE" ]]; then
  cp "$NOTES_FILE" "$WORK/appcast-source/MeetingNotes-$VERSION.md"
fi

"$SPARKLE_BIN/generate_appcast" \
  --account meeting-notes-menu \
  --download-url-prefix "https://github.com/$RELEASE_REPO/releases/download/v$VERSION/" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  --embed-release-notes \
  -o "$ROOT/appcast.xml" \
  "$WORK/appcast-source"

git -C "$ROOT" add Resources/Info.plist appcast.xml
if ! git -C "$ROOT" diff --cached --quiet; then
  git -C "$ROOT" commit -m "Publish Meeting Notes $VERSION"
  git -C "$ROOT" push origin main
fi
PUBLISHED_SHA=$(git -C "$ROOT" rev-parse HEAD)

RELEASE_ARGS=(
  "v$VERSION" "$WORK/$ARCHIVE_NAME"
  --repo "$RELEASE_REPO"
  --target "$PUBLISHED_SHA"
  --title "Meeting Notes $VERSION"
)
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

echo "Published Meeting Notes $VERSION ($BUILD) to https://github.com/$RELEASE_REPO/releases/tag/v$VERSION"
