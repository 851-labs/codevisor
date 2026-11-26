import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const emptyChat = "00000000-0000-4000-8000-000000000001"
const usedChat = "00000000-0000-4000-8000-000000000002"
const codexChat = "00000000-0000-4000-8000-000000000003"

const seedHarnesslessChats = async (filename: string): Promise<void> => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  const project = await run(db.createProject({ folderPath: "/tmp/harnessless-repo" }))
  for (const id of [emptyChat, usedChat, codexChat]) {
    await run(db.createSession({ id, projectId: project.id, harnessId: "codex", title: id }))
  }
  await run(db.close)

  const sqlite = new Database(filename)
  try {
    sqlite.exec(`
      delete from schema_migrations where id = 115;
      update sessions set harness_id = '' where id in ('${emptyChat}', '${usedChat}');
      insert into chat_items (id, session_id, position, role, status, created_at, updated_at)
        values ('used-item', '${usedChat}', 0, 'user', 'complete',
          '2026-09-25T00:00:00.000Z', '2026-09-25T00:00:00.000Z');
    `)
  } finally {
    sqlite.close()
  }
}

describe("harnessless chat repair", () => {
  it("drops empty chats without a harness and gives chats with content Claude Code", async () => {
    const filename = tempDatabase()
    await seedHarnesslessChats(filename)

    const upgraded = await run(makeDatabase({ filename, serverId: "machine-a" }))
    onTestFinished(() => run(upgraded.close))
    const harnesses = new Map(
      (await run(upgraded.listSessions)).map((session) => [session.id, session.harnessId])
    )

    expect(harnesses.has(emptyChat)).toBe(false)
    expect(harnesses.get(usedChat)).toBe("claude-code")
    expect(harnesses.get(codexChat)).toBe("codex")
  })
})
