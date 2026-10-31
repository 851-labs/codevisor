import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { botPath, makeDatabase, type CodevisorDatabaseService } from "./index.js"
import {
  rewindBotModesSql,
  rewindMainSessionSql,
  rewindPluginsSql,
  run,
  tempDatabase
} from "./test-support.js"

const v73Schema = `
  ${rewindBotModesSql}
  ${rewindPluginsSql}
  ${rewindMainSessionSql}
  drop index session_attention_finished_turns;
  alter table session_attention drop column turn_end_state;
  alter table session_attention drop column turn_end_revision;
  alter table session_attention drop column turn_end_stop_reason;
  alter table session_attention drop column turn_end_item_id;
  alter table session_attention drop column turn_end_at;
  drop table session_files;
  alter table files drop column purge_with_chats;
  drop table browser_favicons;
  drop table fleet_pending_turns;
  drop table fleet_deliveries;
  drop table fleet_outbox;
  alter table workspaces drop column remote_bot_parent_session_id;
  alter table workspaces drop column remote_bot_machine_id;
  alter table workspaces drop column remote_bot_id;
  alter table workspaces drop column git_detached_head;
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
      mode: "conversation",
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
    const prompt = { deliveryId: "d-1", receivedAt: "2100-01-01T00:00:00.000Z", text: "t" }
    expect(await run(db.acceptFleetPrompt({ ...prompt, sessionId: "chat-home" }))).toBe(true)
    expect(await run(db.listFleetPendingTurns)).toEqual([])
    expect(await run(db.listFleetMessages)).toEqual([])
    expect(await run(db.findFleetBotLink("remote-child"))).toEqual({
      parentSessionId: "remote:machine-b:chat-b",
      bot: { botId: "bot-elsewhere", botMachineId: "machine-b" }
    })
  })
})
