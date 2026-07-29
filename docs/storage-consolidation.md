# Storage consolidation: one home for a finished meeting

Status: proposal, not implemented.

## The problem

A finished meeting exists twice, and the copy users treat as real is the
derived one.

`AppModel.init()` pins `root` to `~/Library/Application Support/MeetingNotes/Spool`.
`MeetingStore` writes there, and every read path — `completedMeetings(on:)`,
`meetingsForDisplay(on:)`, `deleteMeeting(id:)`, `renameCompletedMeeting(id:title:)`,
recovery, retention — enumerates that root. The folder configured under
Storage (`localPath`, default `~/Documents/Meetings Notes`) receives an rsync
copy.

So the spool is the source of truth, and the archive is a replica. Users open
the archive, point their tooling at it, and reasonably assume the opposite.

Three consequences follow:

1. **Edits to the archive are silently reverted.** `sync(folder:destination:remotely:)`
   runs one-directional rsync with `--delete-delay --delete-excluded`. Anything
   changed or removed in the archive is restored the next time that meeting
   syncs.
2. **The two copies drift.** Today the spool is in week layout
   (`2026/W31/2026-07-28/…`) while the archive is in day layout
   (`2026/07/28/…`), because a migration ran against one and not the other.
3. **Everything is stored twice**, including transcripts and, when retention is
   on, audio.

## The proposal

Split by lifecycle instead of by copy:

| Location | Holds | Written by |
| --- | --- | --- |
| Spool (Application Support) | the active capture, plus interrupted captures awaiting recovery | live capture, finalization |
| Archive (user-configured) | finished meetings, exactly one copy | the finalization move |

On successful finalization the meeting folder is **moved** into the archive
rather than copied. Remote sync then pushes from the archive.

This yields a single invariant that is easy to state and to test:

> A meeting folder in the spool is active or recoverable. A meeting folder in
> the archive is complete.

### Why this is safe to do now

- The app is **not sandboxed** (`Resources/Entitlements.plist` requests only
  audio-input and calendars), so writing to the archive needs no permission
  grant or security-scoped bookmark.
- Spool and archive are normally on the same volume, so the move is a cheap
  rename. A cross-volume archive must fall back to copy-then-delete.
- Recovery already keys off status (`recording`, `processing`, `failed`) plus
  the presence of meaningful audio, so leaving those in the spool preserves
  today's behaviour exactly.

### What it fixes

- One copy of a finished meeting, in the place users already treat as real.
- Drift becomes structurally impossible: there is nothing to drift against.
- The self-sync hazard disappears — after the move the source folder is gone,
  so source and destination can never be the same directory.
- Roughly halves storage for finished meetings.

## Correction to an earlier assumption

In-progress captures are **already** mirrored into the archive today.
`live.md` is written on every `persist()` for a non-complete meeting and is not
excluded from rsync; the archive currently contains `live.md` for several
meetings. Audio is the only thing held back (`--exclude *.wav` unless
`includeAudio`).

So "live capture must stay out of the archive" is not an argument for the
status quo — the status quo does not honour it. It is, however, a reason to
keep the *WAV files* in the spool: they are large, they are rewritten
continuously, and the archive may be on iCloud.

## Design decisions to settle before implementing

1. **Where `current.json` lives.** It sits at the spool root and is synced
   separately (`enqueuePointer`, `pointerMarker`). The live-meeting lookup on
   the remote host reads it. Keeping it in the spool is simplest; it must still
   reach the archive and the remote.
2. **Audio when retention is on.** Today retained WAVs are rsynced to the
   archive and unhidden (`makeRetainedAudioVisible`). A move would carry them
   into a possibly-iCloud folder. Options: move them too (matches today),
   or keep audio spool-only and treat the archive as documents-only.
3. **Archive unavailable at finalization** (external disk, unmounted network
   volume). Proposal: leave the meeting in the spool, mark it, and retry on the
   next launch — the same resilience model the folder-layout migration uses.
4. **`isSafeMeetingPath` and the 4-component assumption.** Sync, delete, and
   rename all derive a relative path from the last four components. Moving the
   root changes what those components are relative to; every call site needs
   auditing.
5. **Read paths.** `completedMeetings`, `meetingsForDisplay`,
   `completedMeetingFoldersAwaitingInsights`, `purgeExpiredTranscripts`,
   `normalizeCompletedMeetingFolders`, and `enqueueCompleteArchive` all
   enumerate the spool and must learn to read the archive for complete
   meetings.
6. **Changing the archive location** in Settings must relocate existing
   meetings, or clearly state that it does not.

## Migration

45 meetings are currently in the spool, 43 in the archive.

- For each **complete** spool meeting, if the archive already holds that
  meeting ID, verify and delete the spool copy; otherwise move it.
- Leave non-complete meetings in the spool.
- Reconcile the two layouts (week vs day) as part of the same pass.
- Move only; never rewrite meeting content. An interrupted run resumes on the
  next launch.
- Take a backup first, and verify the meeting-ID set matches before and after.

## Testing

- The invariant above, asserted directly.
- Finalization moves rather than copies, and the spool folder is gone
  afterwards.
- An interrupted capture stays in the spool and is still recoverable.
- Archive unavailable at finalization leaves the meeting recoverable, not lost.
- Migration preserves every meeting ID, with no content rewritten.
- Delete and rename operate correctly on an archive-resident meeting.
