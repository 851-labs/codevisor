import { expect, it, vi } from "vitest"

import { runBlockingDataUpgrades } from "./data-upgrades.js"
import { memoryDatabase, run } from "./test-support.js"
import { migrateSetupState } from "./transcript-import-upgrade.js"
import { runTranscriptStateUpgrade } from "./transcript-state-upgrade.js"

it("checkpoints setup logs in byte-bounded batches and resumes without duplicating output", async () => {
  const { sqlite, session } = await memoryDatabase()
  const insert = sqlite.prepare(
    "insert into events(server_id, kind, subject_id, created_at, payload) values ('local', 'project.setup', ?, '2026-09-16', ?)"
  )
  const line = "z".repeat(1100000)
  for (let i = 0; i < 2; i++) insert.run(session.id, JSON.stringify({ state: "log", line }))
  expect(() =>
    migrateSetupState(sqlite, () => {
      throw new Error("checkpoint interruption")
    })
  ).toThrow("checkpoint interruption")
  const progress = vi.fn()
  migrateSetupState(sqlite, progress)
  expect(progress).toHaveBeenCalledOnce()
  expect(
    sqlite.prepare("select text_length from setup_state where subject_id = ?").get(session.id)
  ).toEqual({ text_length: 2 * (line.length + 10) })
  migrateSetupState(sqlite, progress)
  expect(progress).toHaveBeenCalledOnce()
})

it("leaves source tables intact when verification fails and records non-Error interruptions", async () => {
  const { sqlite, config, session, db } = await memoryDatabase()
  await run(
    db.appendEvent("session.output", session.id, {
      sessionUpdate: "agent_message_chunk",
      text: "saved"
    })
  )
  sqlite
    .prepare(
      "update backfill_jobs set state = 'running', cursor = '0', completed = 0, total = 99 where id = 'persisted-transcript-state-v1'"
    )
    .run()
  expect(() => runTranscriptStateUpgrade(sqlite, config)).toThrow("verification failed")
  expect(sqlite.prepare("select count(*) as count from session_events").get()).toEqual({ count: 1 })
  expect(
    sqlite
      .prepare("select state from backfill_jobs where id = 'persisted-transcript-state-v1'")
      .get()
  ).toEqual({ state: "failed" })
  sqlite
    .prepare(
      "insert into events(server_id, kind, subject_id, created_at, payload) values ('local', 'project.setup', ?, '2026-09-16', ?)"
    )
    .run(session.id, JSON.stringify({ line: "setup" }))
  const report = vi.fn((progress: { state: string }) => {
    if (progress.state === "running" && report.mock.calls.length > 1) throw "interrupted"
  })
  expect(() =>
    runTranscriptStateUpgrade(sqlite, { ...config, onDataUpgradeProgress: report })
  ).toThrow("interrupted")
  expect(report).toHaveBeenLastCalledWith(
    expect.objectContaining({ state: "failed", error: "interrupted" })
  )
})

it("converts legacy event batches using their byte size as well as their row count", async () => {
  const { sqlite, config, session } = await memoryDatabase()
  sqlite.exec(
    "delete from events; delete from session_events; delete from backfill_jobs where id = 'canonical-session-chat-v1'"
  )
  const insert = sqlite.prepare(
    "insert into events(server_id, kind, subject_id, created_at, payload) values ('local', 'session.updated', ?, '2026-09-16', ?)"
  )
  for (let index = 0; index < 2; index++)
    insert.run(session.id, JSON.stringify({ legacyMetadata: "x".repeat(1100000) }))
  const progress = vi.fn()
  runBlockingDataUpgrades(sqlite, { ...config, onDataUpgradeProgress: progress })
  expect(sqlite.prepare("select count(*) as count from session_events").get()).toEqual({ count: 2 })
  expect(progress).toHaveBeenCalledWith(
    expect.objectContaining({ id: "canonical-session-chat-v1", state: "completed" })
  )
})
