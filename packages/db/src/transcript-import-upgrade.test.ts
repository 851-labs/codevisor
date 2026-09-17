import Database from "better-sqlite3"
import { expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { seedImportedTranscript } from "./transcript-import-upgrade.js"
import { readTranscriptText } from "./transcript-state.js"
import { run, tempDatabase } from "./test-support.js"

it("resumes inside an imported Unicode message without losing or duplicating content", async () => {
  const filename = tempDatabase()
  const db = await run(makeDatabase({ filename, serverId: "local" }))
  const project = await run(db.createProject({ folderPath: "/tmp/import-checkpoint" }))
  const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
  await run(db.appendConversationItem(session.id, "user", "import", "old text", false))
  const item = (await run(db.getTranscriptPage(session.id, undefined, 8))).items[0]!
  await run(db.close)
  const raw = new Database(filename)
  const source = "abcdef😀日本語".repeat(300_000)
  raw.prepare("update chat_parts set text = ? where item_id = ?").run(source, item.id)
  raw.prepare("delete from transcript_entries where item_id = ?").run(item.id)
  raw.prepare("delete from instance_meta where key = 'transcript-import-cursor-v1'").run()
  expect(() =>
    seedImportedTranscript(raw, () => {
      throw new Error("interrupted")
    })
  ).toThrow("interrupted")
  const checkpoint = JSON.parse(
    (
      raw
        .prepare("select value from instance_meta where key = 'transcript-import-cursor-v1'")
        .get() as { value: string }
    ).value
  )
  expect(checkpoint.offset).toBeGreaterThan(0)
  expect(checkpoint.offset).toBeLessThan([...source].length)
  raw.close()
  const reopened = new Database(filename)
  seedImportedTranscript(reopened, () => {})
  expect(readTranscriptText(reopened, item.id, "imported-text")).toBe(source)
  seedImportedTranscript(reopened, () => {})
  expect(readTranscriptText(reopened, item.id, "imported-text")).toBe(source)
  reopened.close()
})
