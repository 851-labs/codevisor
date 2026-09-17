import { isoTimestamp } from "@codevisor/api"
import type Database from "better-sqlite3"

import type { SessionEventRow } from "./rows.js"
import type { CodevisorDatabaseConfig } from "./service.js"
import { activateSyncJournals } from "./sync-journal.js"
import { seedImportedTranscript, migrateSetupState } from "./transcript-import-upgrade.js"
import { projectTranscriptState } from "./transcript-state.js"

const id = "persisted-transcript-state-v1"
const batchBytes = 2 * 1024 * 1024
const batchRows = 256

/** Each checkpoint commits with its projections. A killed upgrade resumes at
 * the next indexed row, without reparsing earlier history or loading a chat. */
export const runTranscriptStateUpgrade = (
  db: Database.Database,
  config: CodevisorDatabaseConfig
): void => {
  const existing = db
    .prepare("select state, cursor, completed, total from backfill_jobs where id = ?")
    .get(id) as
    | { state: string; cursor: string | null; completed: number; total: number }
    | undefined
  if (existing?.state === "completed") return
  let cursor = existing?.cursor ? Number(existing.cursor) : 0
  let completed = existing?.completed ?? 0
  const total =
    existing?.total ??
    Number((db.prepare("select count(*) as n from session_events").get() as { n: number }).n)
  if (existing === undefined)
    db.transaction(() => {
      // Older upgrades can project while constructing canonical chat rows. This
      // pass is the sole checkpointed owner of the final semantic conversion.
      db.exec(
        "delete from transcript_body_chunks; delete from transcript_body_fields; delete from transcript_text_chunks; delete from transcript_heads; delete from transcript_entries; delete from session_state;"
      )
      db.prepare(
        `insert into backfill_jobs (id, name, state, cursor, completed, total, updated_at)
      values (?, 'Persist transcript state', 'running', '0', 0, ?, ?)`
      ).run(id, total, isoTimestamp())
    })()
  const report = (state: "running" | "completed" | "failed", error?: string): void => {
    config.onDataUpgradeProgress?.({
      id,
      name: "Saving chat history",
      state,
      completed,
      total,
      ...(error === undefined ? {} : { error })
    })
  }
  report("running")
  try {
    while (true) {
      // Read sizes first so a row limit cannot accumulate hundreds of MB.
      const candidates = db
        .prepare(
          "select rowid as cursor, length(cast(payload as blob)) as bytes from session_events where rowid > ? order by rowid limit ?"
        )
        .all(cursor, batchRows) as Array<{ cursor: number; bytes: number }>
      if (candidates.length === 0) break
      let bytes = 0
      const batch: number[] = []
      for (const row of candidates) {
        if (batch.length > 0 && bytes + row.bytes > batchBytes) break
        batch.push(row.cursor)
        bytes += row.bytes
      }
      db.transaction(() => {
        for (const next of batch) {
          const event = db
            .prepare("select * from session_events where rowid = ?")
            .get(next) as SessionEventRow
          projectTranscriptState(db, event, event.chat_item_id ?? undefined)
          cursor = next
          completed += 1
        }
        db.prepare(
          "update backfill_jobs set cursor = ?, completed = ?, state = 'running', error = null, updated_at = ? where id = ?"
        ).run(String(cursor), completed, isoTimestamp(), id)
      })()
      report("running")
    }
    seedImportedTranscript(db, () => report("running"))
    migrateSetupState(db, () => report("running"))
    const count = (
      db.prepare("select count(*) as n from session_events where rowid <= ?").get(cursor) as {
        n: number
      }
    ).n
    if (count !== total || completed !== total)
      throw new Error(
        `Transcript migration verification failed: ${completed}/${total} events projected (${count} source rows)`
      )
    db.transaction(() => {
      activateSyncJournals(db)
      db.prepare(
        "update backfill_jobs set state = 'completed', completed = total, error = null, updated_at = ? where id = ?"
      ).run(isoTimestamp(), id)
    })()
    report("completed")
  } catch (cause) {
    const error = cause instanceof Error ? cause.message : String(cause)
    db.prepare(
      "update backfill_jobs set state = 'failed', error = ?, updated_at = ? where id = ?"
    ).run(error, isoTimestamp(), id)
    report("failed", error)
    throw cause
  }
}
