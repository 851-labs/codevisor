# Transcript storage and synchronization

SQLite stores the authoritative transcript and current session/navigation state.
Clients never reconstruct history from provider events. Opening a chat reads
persisted state and does not connect or resume a provider process.

## Permanent content

- `chat_items` identifies and orders user messages and assistant turns.
- `transcript_entries` stores the current text parts, tools, plans, questions,
  and compaction markers within each turn. Stable keys and revisions let an
  arriving page merge with newer live updates.
- `transcript_text_chunks` stores complete message/plan text in small blocks.
  Snapshots carry bounded text previews. Native virtual rows automatically fetch
  the complete text in visible ranges; there is no separate full-text disclosure.
- `transcript_body_fields` and `transcript_body_chunks` store large tool fields
  separately from their headers. Status changes do not copy previous output.
- `session_state`, session columns, and setup state store current configuration,
  goals, pending actions, and setup activity. Setup output is separately paged.
- Attachments remain immutable files in the attachment store. Rows contain
  references. Generated thumbnails have independent, disposable caches;
  removing a thumbnail never removes its original.

Archiving changes visibility and runtime eligibility. It does not delete any of
these transcript or attachment records. Older history and full bodies remain
addressable after journal retention, restart, and unarchive.

## Fetch, then follow

`GET /v1/navigation` returns projects, sessions, workspaces, panes, and the global
event cursor in one SQLite transaction. Metadata mutations record navigation
invalidations in the same transaction. The global stream coalesces those into
entity deltas, including deletions. Native clients apply only affected workspace
layouts and retain their device-local selection and split arrangement.
Repository metadata refreshes in the background with at most two concurrent
probes. Git and filesystem observation never block the navigation request.

`POST /v1/sessions/:id/open` returns saved runtime metadata and an initial
transcript page. Native clients keep draft model and mode selections local until
the user submits work. Transcript pages include their session cursor and current
session state. History, turn details, and large bodies have independent cursors:

- `GET /v1/sessions/:id/transcript` pages message summaries in either direction.
- `GET /v1/sessions/:id/transcript/:itemId/details` pages current turn entries.
- `GET /v1/sessions/:id/transcript/:itemId/body` reads one named body block.

Treat all returned cursors as opaque. Start the corresponding stream at the
snapshot's cursor. A committed update after that boundary is replayed even if
it arrived before the client connected. Text patches carry offsets, generations,
and revisions; replay and overlapping detail pages are idempotent.

The delivery journals retain approximately 2,048 records / 4 MiB per stream.
Replay has a separate 512-record / 512 KiB limit. Older gaps, invalid cursors,
and slow consumers receive `snapshot_required` and fetch current state again.
WebSocket and SSE share this implementation. Fanout wakes a database reader;
it does not accumulate an in-memory replay queue. The old unbounded session
events endpoint returns 410.

Clients bound resident history, detailed turns, live turn entries, text previews,
and decoded media. Moving outside those windows loads permanent pages again.
The server stores complete content independently of those display limits.
Both native clients prefetch history in the direction of scrolling and show a
spinner while a page loads. There are no history pagination buttons. Page
replacement preserves the visible row anchor; it does not count as new scroll
input. Jumping to the bottom fetches the latest window directly.

## Upgrade and restart

Migration 48 creates the new tables. The required data upgrade folds existing
events into current transcript state in checkpointed transactions, normally at
most 256 events / 2 MiB per batch. A single source event must still be parsed as
one JSON value. Imported message text has checkpoints within individual large
messages. Setup history is migrated as a separate bounded stage.

The projection and checkpoint commit together. Interruption resumes after the
last committed batch. Source counts are verified before atomic journal cutover.
Original event tables remain as upgrade backups and are never runtime read
fallbacks. Startup progress is written to the existing upgrade status sidecar.
Completed upgrades are skipped on subsequent boots.

Restart recovery loads only sessions with durable work: queued prompts, active
goals, or running background tasks. Merely having opened an idle chat does not
schedule it for provider resume. Codex stdout parsing runs in a worker, scans
incoming chunks once, and skips returned `thread.turns` history as it arrives.
The provider's rollout file remains intact; Codevisor uses its own transcript.
