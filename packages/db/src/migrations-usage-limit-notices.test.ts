import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const limitedChat = "00000000-0000-4000-8000-000000000001"
const otherChat = "00000000-0000-4000-8000-000000000002"
const fiveHourLimit = "You've hit your 5-hour limit · resets 8:10pm (America/Los_Angeles)"

const open = async (filename: string): Promise<CodevisorDatabaseService> => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  onTestFinished(() => run(db.close))
  return db
}

const seedV80 = async (filename: string) => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  const project = await run(db.createProject({ folderPath: "/tmp/notices-repo", name: "repo" }))
  for (const id of [limitedChat, otherChat]) {
    await run(
      db.createWorkspaceWithSession({
        workspace: { id: `ws-${id}`, projectId: project.id, name: id, hasCustomName: false },
        session: { id, projectId: project.id, harnessId: "claude-code", title: id }
      })
    )
  }
  const notices: ReadonlyArray<[string, "user" | "notice", string]> = [
    [limitedChat, "user", "Summarize today's PRs"],
    [limitedChat, "notice", fiveHourLimit],
    [limitedChat, "notice", "Refused"],
    [limitedChat, "user", fiveHourLimit],
    [otherChat, "notice", fiveHourLimit]
  ]
  for (const [sessionId, sender, text] of notices) {
    await run(db.appendBotMessage(sessionId, { sender, text }))
  }
  await run(db.close)
  const sqlite = new Database(filename)
  try {
    const insertStop = sqlite.prepare(
      `insert into chat_items (id, session_id, position, role, status, created_at, updated_at, stop_detail, stop_kind)
       values (?, ?, ?, 'assistant', 'complete', '2026-10-27T00:00:00.000Z', '2026-10-27T00:00:00.000Z', ?, ?)`
    )
    insertStop.run("limited-stop", limitedChat, 0, fiveHourLimit, "usageLimit")
    insertStop.run("refused-stop", limitedChat, 1, "Refused", null)
    insertStop.run("other-stop", otherChat, 0, fiveHourLimit, null)
    sqlite.exec("delete from schema_migrations where id >= 81")
  } finally {
    sqlite.close()
  }
}

const conversation = async (db: CodevisorDatabaseService, sessionId: string) =>
  (await run(db.listBotMessages(sessionId, undefined, 10))).messages.map((message) => [
    message.sender,
    message.text
  ])

describe("usage-limit bot notice upgrade", () => {
  it("drops notices that repeat a chat's usage-limit stop and keeps every other message", async () => {
    const filename = tempDatabase()
    await seedV80(filename)

    const db = await open(filename)

    expect(await conversation(db, limitedChat)).toEqual([
      ["user", "Summarize today's PRs"],
      ["notice", "Refused"],
      ["user", fiveHourLimit]
    ])
    expect(await conversation(db, otherChat)).toEqual([["notice", fiveHourLimit]])
  })
})
