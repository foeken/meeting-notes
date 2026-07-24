# Meeting Notes Menu

A deliberately small, native macOS menu-bar utility for private meeting
transcripts. It records the microphone and system audio as separate tracks,
writes a timestamped live Markdown transcript during the call, and replaces it
with a locally generated transcript plus structured meeting notes after
recording stops.

The finalized archive always lives in a local directory, using
`~/Documents/Meetings Notes` by default. An optional SSH destination can receive
a second copy. The recording Mac keeps a private Application Support spool so
capture never depends on either destination being reachable and interrupted
syncs can retry.

## Product behavior

- Menu-bar-only SwiftUI app; no Dock icon and no meeting dashboard.
- EventKit suggests the current calendar event title. The title is editable.
- AVAudioEngine records the microphone as a separate source track.
- ScreenCaptureKit records system playback, including Zoom and Teams, as the
  remote side. It does not use meeting bots or join calls.
- FluidAudio/Nemotron 3.5 creates a streaming multilingual transcript locally,
  with automatic language detection and roughly 1.12-second model chunks.
- Recording can be paused and resumed without closing the meeting or losing the
  existing WAV recovery tracks.
- While recording, the app prevents idle system sleep. Explicit sleep or closing
  the lid still pauses capture, and the app remains paused after wake until
  Resume is pressed. A
  closed laptop cannot capture while macOS itself is asleep; capture continues
  without interruption when the Mac remains awake in supported clamshell mode.
- The sleep-prevention activity is released while paused, processing, or idle.
- `live.md` is rewritten atomically after every live turn, with an elapsed
  timestamp on each turn.
- On stop, FluidAudio runs Nemotron 3.5 ASR on both source tracks. Transcript
  turns intentionally use the neutral speaker name `Unknown`. OpenAI `gpt-5.6-sol`
  with medium reasoning then derives
  the summary, topics, decisions, actions, and evidence timestamps from text only.
  After success it writes `meeting.md` and `transcript.md`, then deletes
  `live.md`, `microphone.wav`, and `system.wav`. If final processing fails, the
  live transcript and WAV tracks are retained for recovery.
- Long transcripts are processed in bounded chronological chunks and merged
  through a hierarchical structured-output pass, so enrichment does not depend
  on the whole meeting fitting in one request.
- Archive updates always use rsync to the local archive and can additionally
  sync over SSH. WAV source tracks are excluded and deleted after successful processing by default. Users
  can enable **Keep audio recordings** to retain both tracks and sync them to the
  configured archive. Transcription runs locally.

## Build and run

Requirements: Apple Silicon, macOS 14+, Xcode 16+.

```sh
cd ~/Code/meeting-notes
chmod +x scripts/stable-build.sh
scripts/stable-build.sh
```

For stable macOS privacy permissions across rebuilds, set
`MEETING_NOTES_CODE_SIGN_IDENTITY` to an Apple Development certificate name.
The build script otherwise uses an ad-hoc signature with a stable designated
requirement and prints a warning.

On first use macOS asks for Calendar, Microphone, and Screen & System Audio
Recording access. The first transcription downloads the local Nemotron 3.5 model assets.

The **…** menu includes **Check for Updates…**. Automatic update checks and the
standard update UI are provided by Sparkle. Published builds read their signed
appcast over HTTPS from this repository; the update signing key remains in the
release Mac's Keychain.

### Publishing a release

Public releases require a Developer ID Application certificate, a configured
`notarytool` Keychain profile, the `meeting-notes-menu` Sparkle signing key, and
authenticated GitHub CLI access. Signed archives are attached to GitHub Releases,
while `appcast.xml` is versioned alongside the source. Private signing material
never enters the repository.

```sh
export MEETING_NOTES_NOTARY_PROFILE="meeting-notes-menu"
scripts/release.sh 0.3.0 3 ~/Desktop/meeting-notes-0.3.0.md
```

The script updates both bundle version fields, builds and signs the app,
submits it for notarization, staples the ticket, generates an EdDSA-signed
appcast, commits the version and feed, and uploads the archive to a GitHub Release.

## Archive and AI retrieval settings

Open **Settings** from the menu-bar window to choose the local archive folder.
New installations default to `Meetings Notes` in Documents. Optionally enable
remote sync and enter an SSH host and archive path. Host-key checking remains
enabled.

The app does not depend on a particular search or indexing product. Under
**Hooks**, an optional archive-change command can run on this Mac or on
the configured remote server. It runs from inside the archive folder
after finalized meetings are added, regenerated, renamed, edited, or deleted.
A configured command should be non-interactive, idempotent, and safe to retry.

Current-meeting tools can read `live.md` directly and therefore work midway
through a meeting. Historical tools can use `meeting.md` for semantic recall
and `transcript.md` for complete timestamped evidence. Partial speech in
`live.md` should never enter a historical index.

## File layout

```text
Private spool on the recording Mac:
  2026/07/14/1030-roadmap-planning-a1b2c3d4/
    meeting.json
    live.md          # present during capture and processing
    microphone.wav   # temporary recovery track; deleted after success
    system.wav       # temporary recovery track; deleted after success

Configured archive (local or remote):
  2026/07/14/
    1030-roadmap-planning-a1b2c3d4/
      meeting.md       # structured meeting notes
      transcript.md    # full timestamped evidence
      live.md          # present only until final transcription succeeds
      meeting.json     # crash recovery/state
```

## Current limits

- ScreenCaptureKit captures all system playback, not only a selected Zoom or
  Teams process. Headphones are recommended to avoid acoustic echo.
- Transcript turns are deliberately unattributed; the app does not infer speaker identity.

## Attribution

The capture architecture follows Muesli's proven native approach. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
