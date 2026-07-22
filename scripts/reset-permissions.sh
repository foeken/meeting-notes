#!/bin/bash
# Resets macOS privacy (TCC) permission state for Meeting Notes so the system
# shows fresh permission prompts on next use. Run this if permission prompts
# stop appearing or requests are silently denied after rebuilds/signing changes.
#
# Usage: ./scripts/reset-permissions.sh
# Afterwards, relaunch the app with ./scripts/stable-build.sh and trigger the
# feature (e.g. press Record) to get the new prompt.
set -euo pipefail

BUNDLE_ID="app.meetingnotes.menu"

SERVICES=(
  Microphone      # local capture of your voice
  ScreenCapture   # system-audio capture from calls
  Calendar        # meeting title suggestions
)

for service in "${SERVICES[@]}"; do
  if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
    echo "reset: $service"
  else
    echo "warning: could not reset $service (may not be supported on this macOS version)" >&2
  fi
done

echo "Done. Relaunch with ./scripts/stable-build.sh, then trigger recording to re-prompt."
