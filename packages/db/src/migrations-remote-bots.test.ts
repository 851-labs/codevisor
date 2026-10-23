import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { botPath, makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const v73Schema = `
  drop table fleet_deliveries;
  drop table fleet_outbox;
  alter table workspaces drop column remote_bot_parent_session_id;
  alter table workspaces drop column remote_bot_machine_id;
  alter table workspaces drop column remote_bot_id;
  delete from schema_migrations where id >= 74;
`

const useWorktreesRoot = (): void => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-remote-bots-"))
  const previous = process.env["CODEVISOR_WORKTREES_ROOT"]
  process.env["CODEVISOR_WORKTREES_ROOT"] = root
  onTestFinished(() => {
    if (previous === undefined) delete process.env["CODEVISOR_WORKTREES_ROOT"]
    else process.env["CODEVISOR_WORKTREES_ROOT"] = previous
    rmSync(root, { force: true, recursive: true })
  })
}

const seedV73 = async (filename: string) => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  const repo = await run(db.createProject({ folderPath: "/tmp/remote-bots-repo", name: "repo" }))
  const home = await run(db.createProject({ folderPath: botPath("helper"), name: "Helper" }))
  await run(
    db.createWorkspaceWithSession({
      workspace: { id: "ws-home", projectId: home.id, name: "Helper", hasCustomName: false },
      session: { id: "chat-home", projectId: home.id, harnessId: "codex", title: "Helper" }
    })
  )
  await run(
    db.createBot({
      id: "bot-helper",
      name: "Helper",
      symbolName: "sparkles",
      slug: "helper",
      projectId: home.id,
      sessionId: "chat-home",
      workspaceId: "ws-home",
      conversational: true,
      projects: []
    })
  )
  const chatIn = (id: string, botId?: string) =>
    run(
      db.createWorkspaceWithSession({
        workspace: {
          id: `ws-${id}`,
          projectId: repo.id,
          name: id,
          hasCustomName: false,
          ...(botId === undefined ? {} : { botId })
        },
        session: { id, projectId: repo.id, harnessId: "codex", title: id }
      })
    )
  await chatIn("child", "bot-helper")
  await chatIn("plain")
  await run(db.close)
  const sqlite = new Database(filename)
  try {
    sqlite.exec(v73Schema)
  } finally {
    sqlite.close()
  }
  return repo.id
}

const reopen = async (filename: string): Promise<CodevisorDatabaseService> => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  onTestFinished(() => run(db.close))
  return db
}

describe("remote bot workspace upgrade", () => {
  it("keeps a populated v73 database's bots and workspaces and adds remote bot links and fleet delivery", async () => {
    useWorktreesRoot()
    const filename = tempDatabase()
    const repoId = await seedV73(filename)

    const db = await reopen(filename)
    const workspaces = await run(db.listWorkspaces)
    const byId = (id: string) => workspaces.find((workspace) => workspace.id === id)
    const linked = await run(
      db.createWorkspaceWithSession({
        workspace: {
          id: "ws-remote",
          projectId: repoId,
          name: "remote",
          hasCustomName: false,
          botId: "bot-elsewhere",
          botMachineId: "machine-b",
          botParentSessionId: "remote:machine-b:chat-b"
        },
        session: { id: "remote-child", projectId: repoId, harnessId: "codex", title: "remote" }
      })
    )

    expect(byId("ws-child")).toMatchObject({ botId: "bot-helper" })
    expect(byId("ws-child")?.botMachineId).toBeUndefined()
    expect(byId("ws-plain")?.botId).toBeUndefined()
    expect(await run(db.findBotLinkForSession("child"))).toEqual({ botId: "bot-helper" })
    expect(await run(db.findFleetBotLink("child"))).toBeUndefined()
    expect(linked.workspace).toMatchObject({ botId: "bot-elsewhere", botMachineId: "machine-b" })
    expect(await run(db.recordFleetDelivery("d-1", "2100-01-01T00:00:00.000Z"))).toBe(true)
    expect(await run(db.listFleetMessages)).toEqual([])
    expect(await run(db.findFleetBotLink("remote-child"))).toEqual({
      parentSessionId: "remote:machine-b:chat-b",
      bot: { botId: "bot-elsewhere", botMachineId: "machine-b" }
    })
  })
})
