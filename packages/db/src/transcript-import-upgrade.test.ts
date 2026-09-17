import Database from "better-sqlite3"
import { expect, it, onTestFinished, vi } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"
import { seedImportedTranscript } from "./transcript-import-upgrade.js"
import { readTranscriptText } from "./transcript-state.js"

it.each([1, 2])(
  "resumes inside an imported Unicode message after a %i-block checkpoint without losing or duplicating content",
  async (blocksPerCheckpoint) => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    onTestFinished(() => run(db.close))
    const project = await run(db.createProject({ folderPath: "/tmp/import-checkpoint" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.appendConversationItem(session.id, "user", "import", "old text", false))
    const item = (await run(db.getTranscriptPage(session.id, undefined, 8))).items[0]!
    await run(db.close)
    const raw = new Database(filename)
    onTestFinished(() => {
      raw.close()
    })
    // Cross real 8192-code-point blocks, including their UTF-16 storage boundaries.
    const source = "abcdef😀日本語".repeat(2_000)
    raw.prepare("update chat_parts set text = ? where item_id = ?").run(source, item.id)
    raw.prepare("delete from transcript_entries where item_id = ?").run(item.id)
    raw.prepare("delete from instance_meta where key = 'transcript-import-cursor-v1'").run()
    const interrupted = vi.fn(() => {
      throw new Error("interrupted")
    })
    expect(() => seedImportedTranscript(raw, interrupted, blocksPerCheckpoint)).toThrow(
      "interrupted"
    )
    expect(interrupted).toHaveBeenCalledOnce()
    const checkpoint = JSON.parse(
      (
        raw
          .prepare("select value from instance_meta where key = 'transcript-import-cursor-v1'")
          .get() as { value: string }
      ).value
    )
    expect(checkpoint.offset).toBe(1 + blocksPerCheckpoint * 8192)
    const committedPrefix = [...source].slice(0, checkpoint.offset - 1).join("")
    expect(committedPrefix.length).toBeLessThan(source.length)
    expect(readTranscriptText(raw, item.id, "imported-text")).toBe(committedPrefix)
    raw.close()
    const reopened = new Database(filename)
    onTestFinished(() => {
      reopened.close()
    })
    // Resume with production defaults, so the persisted cursor is batch-size independent.
    const progress = vi.fn()
    seedImportedTranscript(reopened, progress)
    expect(progress).toHaveBeenCalledOnce()
    expect(readTranscriptText(reopened, item.id, "imported-text")).toBe(source)
    seedImportedTranscript(reopened, progress)
    expect(progress).toHaveBeenCalledOnce()
    expect(readTranscriptText(reopened, item.id, "imported-text")).toBe(source)
  }
)

it.each([0, -1, 1.5, NaN, Infinity])("rejects an invalid checkpoint batch size of %s", (size) => {
  const db = new Database(":memory:")
  onTestFinished(() => {
    db.close()
  })
  expect(() => seedImportedTranscript(db, () => {}, size)).toThrow(
    "blocksPerCheckpoint must be a positive safe integer"
  )
})
