import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { botPath, makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const rewindConversationBotsSql = `
  alter table bots add column conversational integer not null default 0;
  alter table bots add column mode text not null default 'transcript';
  update bots set mode = 'bubbles' where id = 'bot-bubbles';
  delete from schema_migrations where id = 96;
`

const useWorktreesRoot = (): void => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-conversation-bots-"))
  const previous = process.env["CODEVISOR_WORKTREES_ROOT"]
  process.env["CODEVISOR_WORKTREES_ROOT"] = root
  onTestFinished(() => {
    if (previous === undefined) delete process.env["CODEVISOR_WORKTREES_ROOT"]
    else process.env["CODEVISOR_WORKTREES_ROOT"] = previous
    rmSync(root, { force: true, recursive: true })
  })
}

const seedBot = async (db: CodevisorDatabaseService, slug: string): Promise<void> => {
  const home = await run(db.createProject({ folderPath: botPath(slug), name: slug }))
  await run(
    db.createWorkspaceWithSession({
      workspace: { id: `ws-${slug}`, projectId: home.id, name: slug, hasCustomName: false },
      session: { id: `chat-${slug}`, projectId: home.id, harnessId: "codex", title: slug }
    })
  )
  await run(
    db.createBot({
      id: `bot-${slug}`,
      name: slug,
      symbolName: "sparkles",
      mascot: { color: "mint", hat: "none", eyewear: "none" },
      slug,
      projectId: home.id,
      sessionId: `chat-${slug}`,
      workspaceId: `ws-${slug}`,
      projects: []
    })
  )
}

const seedTranscriptBots = async (filename: string): Promise<void> => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  await seedBot(db, "transcript")
  await seedBot(db, "bubbles")
  await run(db.close)
  const sqlite = new Database(filename)
  try {
    sqlite.exec(rewindConversationBotsSql)
  } finally {
    sqlite.close()
  }
}

const runSilentTurn = async (db: CodevisorDatabaseService, sessionId: string): Promise<void> => {
  const turn = { initiatedBy: "agent", turnId: "turn" }
  await run(db.appendEvent("session.updated", sessionId, { ...turn, turnState: "started" }))
  await run(
    db.appendEvent("session.output", sessionId, { role: "assistant", text: "done", turnId: "turn" })
  )
  await run(db.appendEvent("session.updated", sessionId, { ...turn, turnState: "ended" }))
}

describe("conversation-only bots upgrade", () => {
  it("keeps every bot and treats the chats of former transcript and bubbles bots as conversations", async () => {
    useWorktreesRoot()
    const filename = tempDatabase()
    await seedTranscriptBots(filename)

    const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
    onTestFinished(() => run(db.close))
    for (const chat of ["chat-transcript", "chat-bubbles"]) await runSilentTurn(db, chat)

    expect((await run(db.listBots)).map((bot) => bot.id).toSorted()).toEqual([
      "bot-bubbles",
      "bot-transcript"
    ])
    for (const chat of ["chat-transcript", "chat-bubbles"]) {
      expect(await run(db.getSessionSummary(chat))).toMatchObject({
        sidebarState: "idle",
        unreadCount: 0
      })
    }
  })
})
