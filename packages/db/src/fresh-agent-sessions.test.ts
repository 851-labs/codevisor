import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { rewindFreshAgentSessionsSql, run, tempDatabase } from "./test-support.js"

const unusedChat = "00000000-0000-4000-8000-000000000001"
const usedChat = "00000000-0000-4000-8000-000000000002"
const importedChat = "00000000-0000-4000-8000-000000000003"
const deferredChat = "00000000-0000-4000-8000-000000000004"

const open = async (filename: string): Promise<CodevisorDatabaseService> => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  onTestFinished(() => run(db.close))
  return db
}

const seedV82 = async (filename: string) => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  const project = await run(db.createProject({ folderPath: "/tmp/fresh-repo", name: "repo" }))
  const chats: ReadonlyArray<[string, "codevisor" | "imported", string]> = [
    [unusedChat, "codevisor", "agent-unused"],
    [usedChat, "codevisor", "agent-used"],
    [importedChat, "imported", "agent-imported"],
    [deferredChat, "codevisor", ""]
  ]
  for (const [id, origin, agentSessionId] of chats) {
    await run(
      db.createSession({
        id,
        projectId: project.id,
        harnessId: "claude-code",
        origin,
        agentSessionId
      })
    )
  }
  await run(db.appendConversationItem(usedChat, "user", undefined, "hello", false))
  await run(db.close)
  const sqlite = new Database(filename)
  try {
    sqlite.exec(rewindFreshAgentSessionsSql)
  } finally {
    sqlite.close()
  }
}

const freshChats = async (db: CodevisorDatabaseService) => {
  const fresh: Array<string> = []
  for (const id of [unusedChat, usedChat, importedChat, deferredChat]) {
    if (await run(db.isAgentSessionFresh(id))) fresh.push(id)
  }
  return fresh
}

describe("fresh agent sessions", () => {
  it("marks only Codevisor chats whose agent was started but never sent a message", async () => {
    const filename = tempDatabase()
    await seedV82(filename)

    const db = await open(filename)

    expect(await freshChats(db)).toEqual([unusedChat])
  })

  it("stays fresh until a turn starts, and only for the agent session it was marked for", async () => {
    const db = await open(tempDatabase())
    const project = await run(db.createProject({ folderPath: "/tmp/fresh-live", name: "live" }))
    const session = await run(
      db.createSession({ projectId: project.id, harnessId: "claude-code", agentSessionId: "first" })
    )
    await run(db.markAgentSessionFresh(session.id, "first"))
    expect(await run(db.isAgentSessionFresh(session.id))).toBe(true)

    await run(db.updateSession(session.id, { agentSessionId: "replaced" }))
    expect(await run(db.isAgentSessionFresh(session.id))).toBe(false)

    await run(db.markAgentSessionFresh(session.id, "replaced"))
    await run(db.appendEvent("session.updated", session.id, { turnId: "t1", turnState: "started" }))
    expect(await run(db.isAgentSessionFresh(session.id))).toBe(false)
  })
})
