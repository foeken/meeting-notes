<img width="1254" height="1254" alt="Generated image 1 (1)" src="https://github.com/user-attachments/assets/3b0ea0ec-2799-4515-afca-6d0b940fa90b" />


# Meeting Notes

**Every meeting, remembered. Nothing leaves your Mac without your say-so.**

Meeting Notes is a small menu-bar app that records your meetings, transcribes
them on your own Mac, and turns each one into clean, searchable notes. No
meeting bots joining your calls, no audio uploaded to someone else's cloud —
just a quiet icon in your menu bar and a growing archive of everything you
discussed.

## How it works

1. **Press Record.** The app picks up your microphone and the other side of
   the call (Zoom, Teams, Meet — anything your Mac plays). If a meeting is on
   your calendar, the title is already filled in.
2. **Read along live.** A transcript builds while you talk, so you can ask
   "what was just said?" mid-meeting. Pause and resume whenever you like.
3. **Stop, and it finishes itself.** After the meeting, the app produces a
   full word-for-word transcript plus structured notes: a summary, the topics
   discussed, and timestamps you can jump back to.

Everything lands as plain Markdown files in a folder you choose
(`Documents/Meetings Notes` by default) — readable anywhere, forever, with no
lock-in.

## What makes it different

- **Private by design.** Recording and transcription happen entirely on your
  Mac. Audio recordings are deleted right after processing unless you choose
  to keep them. Only the finished transcript text is sent to OpenAI to write
  the structured notes.
- **Speaks your languages.** Transcription is multilingual with automatic
  language detection, and your notes can be written in the language you prefer.
- **Stays out of the way.** No Dock icon, no dashboard, no accounts to manage.
  It notices when a video call starts, offers to record, and stops when the
  call ends.
- **Built for follow-up.** Rename meetings, regenerate summaries, open a
  Codex task about any meeting, and set old word-for-word transcripts to
  delete themselves automatically after a period you choose.
- **Optional second copy on another Mac.** If you keep an always-on Mac (a
  home server, an office machine), the app can mirror your archive to it over
  SSH — handy for backup or for running search and indexing tools where the
  archive lives. This is entirely optional; everything works with just the
  local folder.

## Why this exists

Meeting Notes grew out of a simple shift: taking notes used to be how you
stayed present in a meeting. With live local transcription, the app captures
*what was said*, so your own typing can capture what you think it means and
what should happen next. Each meeting can even open its own Codex task, with
the live transcript as context — ask "what was just discussed?" mid-call, or
extract decisions and follow-ups when it suits you.

André wrote about how this fits into a full AI-first daily workflow in
[After Orbital: Codex as My Daily Driver](https://dreet.je/writing/after-orbital/).

---

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
