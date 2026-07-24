#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
APP="$ROOT/Meeting Notes.app"
EXECUTABLE="$APP/Contents/MacOS/MeetingNotes"
POINTER="$HOME/Library/Application Support/MeetingNotes/Spool/current.json"

if [[ "${1:-}" == "--recover-running-meeting" ]]; then
  if pgrep -x MeetingNotes >/dev/null; then
    echo "error: Meeting Notes is already running" >&2
    exit 5
  fi
  if [[ ! -x "$EXECUTABLE" ]]; then
    echo "error: canonical app executable is missing: $EXECUTABLE" >&2
    exit 6
  fi
  if [[ ! -f "$POINTER" ]]; then
    echo "error: no meeting recovery pointer exists" >&2
    exit 7
  fi
  ACTIVE=$(plutil -extract active raw -o - "$POINTER" 2>/dev/null || echo false)
  CAPTURE_STATE=$(plutil -extract captureState raw -o - "$POINTER" 2>/dev/null || echo unknown)
  if [[ "$ACTIVE" != "true" ]]; then
    echo "error: recovery launch requires an active meeting pointer" >&2
    exit 8
  fi
  echo "Verifying the existing canonical app for $CAPTURE_STATE meeting recovery…"
  codesign --verify --deep --strict --verbose=2 "$APP"
  plutil -lint "$APP/Contents/Info.plist"
  open -n "$APP"
  for _ in {1..50}; do
    PIDS=(${(f)"$(pgrep -x MeetingNotes || true)"})
    if (( ${#PIDS[@]} == 1 )); then
      RUNNING_COMMAND=$(ps -p "$PIDS[1]" -o command=)
      if [[ "$RUNNING_COMMAND" == "$EXECUTABLE" ]]; then
        echo "Recovery app running: $APP (PID $PIDS[1], exact executable verified)"
        exit 0
      fi
    fi
    sleep 0.1
  done
  echo "error: the canonical recovery app did not start cleanly" >&2
  exit 9
fi

if [[ -f "$POINTER" ]]; then
  ACTIVE=$(plutil -extract active raw -o - "$POINTER" 2>/dev/null || echo false)
  CAPTURE_STATE=$(plutil -extract captureState raw -o - "$POINTER" 2>/dev/null || echo unknown)
  if [[ "$ACTIVE" == "true" || "$CAPTURE_STATE" == "starting" || "$CAPTURE_STATE" == "recording" || "$CAPTURE_STATE" == "paused" || "$CAPTURE_STATE" == "processing" ]]; then
    echo "error: a meeting is $CAPTURE_STATE; wait until capture is complete before rebuilding" >&2
    exit 2
  fi
fi

echo "Stopping old Meeting Notes processes…"
killall MeetingNotes 2>/dev/null || true
for _ in {1..50}; do
  if ! pgrep -x MeetingNotes >/dev/null; then
    break
  fi
  sleep 0.1
done
if pgrep -x MeetingNotes >/dev/null; then
  echo "error: an old Meeting Notes process did not stop" >&2
  exit 3
fi

echo "Running strict tests…"
swift test --package-path "$ROOT" -Xswiftc -warnings-as-errors
zsh -n "$ROOT/scripts/build-app.sh"
zsh -n "$ROOT/scripts/stable-build.sh"
zsh -n "$ROOT/scripts/release.sh"

echo "Building app…"
if [[ -z "${MEETING_NOTES_CODE_SIGN_IDENTITY:-}" ]]; then
  SIGNING_IDENTITY=$(
    security find-identity -v -p codesigning \
      | awk -F'"' '/Apple Development:/ { print $2; exit }'
  )
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "error: no Apple Development signing identity is available" >&2
    exit 4
  fi
  export MEETING_NOTES_CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
fi
"$ROOT/scripts/build-app.sh"
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"

echo "Launching one fresh instance…"
open -n "$APP"
for _ in {1..50}; do
  PIDS=(${(f)"$(pgrep -x MeetingNotes || true)"})
  if (( ${#PIDS[@]} == 1 )); then
    RUNNING_COMMAND=$(ps -p "$PIDS[1]" -o command=)
    if [[ "$RUNNING_COMMAND" == "$EXECUTABLE" ]]; then
      echo "Stable build running: $APP (PID $PIDS[1], exact executable verified)"
      exit 0
    fi
  fi
  sleep 0.1
done

PIDS=(${(f)"$(pgrep -x MeetingNotes || true)"})
echo "error: expected exactly one $EXECUTABLE process; found ${#PIDS[@]} MeetingNotes process(es)" >&2
for PID in $PIDS; do
  ps -p "$PID" -o pid=,command= >&2 || true
done
exit 4
