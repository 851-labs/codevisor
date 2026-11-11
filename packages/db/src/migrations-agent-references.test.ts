import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { rewindAgentReferencesSql, run, tempDatabase } from "./test-support.js"

const legacyChildren = [
  ["local-child", "agent", "parent"],
  ["remote-child", "agent", "remote2:machine-b:chat-b"],
  ["legacy-remote-child", "agent", "remote:machine-c:chat-c"],
  ["fork", "user", "parent"]
] as const

const seedV96 = async (filename: string): Promise<void> => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  const project = await run(db.createProject({ folderPath: "/tmp/agent-references" }))
  await run(db.createSession({ id: "parent", projectId: project.id, harnessId: "codex" }))
  for (const [id] of legacyChildren) {
    await run(
      db.createWorkspaceWithSession({
        workspace: { id: `ws-${id}`, projectId: project.id, name: id, hasCustomName: false },
        session: { id, projectId: project.id, harnessId: "codex", title: id }
      })
    )
  }
  await run(db.close)
  const sqlite = new Database(filename)
  try {
    sqlite.exec(rewindAgentReferencesSql)
    const link = sqlite.prepare(
      "update sessions set created_by = ?, parent_session_id = ? where id = ?"
    )
    for (const [id, createdBy, parent] of legacyChildren) link.run(createdBy, parent, id)
    sqlite
      .prepare(
        "update workspaces set remote_bot_id = 'bot-b', remote_bot_machine_id = ? where id = ?"
      )
      .run("machine-b", "ws-remote-child")
  } finally {
    sqlite.close()
  }
}

const reopen = async (filename: string): Promise<CodevisorDatabaseService> => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  onTestFinished(() => run(db.close))
  return db
}

describe("agent references upgrade", () => {
  it("splits each old parent key into who created or forked the chat and on which machine", async () => {
    const filename = tempDatabase()
    await seedV96(filename)

    const db = await reopen(filename)
    const references = async (id: string) => {
      const session = await run(db.getSessionSummary(id))
      return [
        session.createdByAgentId,
        session.createdByAgentMachineId,
        session.forkedFromAgentId,
        session.forkedFromAgentMachineId
      ]
    }

    expect(await references("local-child")).toEqual(["parent", "machine-a", undefined, undefined])
    expect(await references("remote-child")).toEqual(["chat-b", "machine-b", undefined, undefined])
    expect(await references("legacy-remote-child")).toEqual([
      "chat-c",
      "machine-c",
      undefined,
      undefined
    ])
    expect(await references("fork")).toEqual([undefined, undefined, "parent", "machine-a"])
  })

  it("names a workspace a bot started after its main chat, like any other workspace", async () => {
    const filename = tempDatabase()
    await seedV96(filename)

    const db = await reopen(filename)
    await run(db.updateSession("remote-child", { title: "Fix the flaky test" }))

    const workspace = (await run(db.listWorkspaces)).find((w) => w.id === "ws-remote-child")
    expect(workspace?.name).toBe("Fix the flaky test")
  })
})
