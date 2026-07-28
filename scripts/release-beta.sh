#!/bin/zsh
set -euo pipefail

# Publishes a beta build to the beta update channel.
#
#   scripts/release-beta.sh 1.2.0-beta.1 6 ~/Desktop/notes.md
#
# This is `scripts/release.sh --beta` with one extra guard: a beta must not
# reuse a build number that a published feed already carries, because Sparkle
# orders updates by CFBundleVersion and a duplicate would be invisible to one
# of the two channels.

ROOT=${0:A:h:h}
VERSION=${1:?usage: scripts/release-beta.sh VERSION BUILD [RELEASE_NOTES_FILE]}
BUILD=${2:?usage: scripts/release-beta.sh VERSION BUILD [RELEASE_NOTES_FILE]}
NOTES_FILE=${3:-}

if ! [[ "$BUILD" =~ '^[0-9]+$' ]]; then
  echo "error: BUILD must be an integer" >&2
  exit 2
fi

# Betas are expected to carry a prerelease suffix. Publishing a bare x.y.z to
# the beta channel is almost always a mistake: the same version would later
# ship as the stable release and the two would be indistinguishable.
if ! [[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z.]+$' ]]; then
  echo "error: a beta version needs a prerelease suffix, for example 1.2.0-beta.1" >&2
  exit 2
fi

if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
  echo "error: release notes file does not exist: $NOTES_FILE" >&2
  exit 2
fi

# Both feeds are checked, not just the beta one: a build number already used by
# a stable release would collide just as badly.
for feed in appcast.xml appcast-beta.xml; do
  [[ -f "$ROOT/$feed" ]] || continue
  if grep -q "<sparkle:version>$BUILD</sparkle:version>" "$ROOT/$feed"; then
    echo "error: build $BUILD is already published in $feed; pick a higher number" >&2
    exit 2
  fi
done

exec "$ROOT/scripts/release.sh" --beta "$VERSION" "$BUILD" ${NOTES_FILE:+"$NOTES_FILE"}
