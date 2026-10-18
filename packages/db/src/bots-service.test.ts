import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { botPath, makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const useWorktreesRoot = (): string => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-bots-"))
  const previous = process.env["CODEVISOR_WORKTREES_ROOT"]
  process.env["CODEVISOR_WORKTREES_ROOT"] = root
  onTestFinished(() => {
    if (previous === undefined) delete process.env["CODEVISOR_WORKTREES_ROOT"]
    else process.env["CODEVISOR_WORKTREES_ROOT"] = previous
    rmSync(root, { force: true, recursive: true })
  })
  return root
}

const openDatabase = async (): Promise<CodevisorDatabaseService> => {
  const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
  onTestFinished(() => run(db.close))
  return db
}

const seedBot = async (db: CodevisorDatabaseService) => {
  const api = await run(db.createProject({ folderPath: "/tmp/bots-api", name: "api" }))
  const web = await run(db.createProject({ folderPath: "/tmp/bots-web", name: "web" }))
  const home = await run(db.createProject({ folderPath: botPath("helper"), name: "Helper" }))
  await run(
    db.createWorkspaceWithSession({
      workspace: { id: "ws-helper", projectId: home.id, name: "Helper", hasCustomName: false },
      session: { id: "chat-helper", projectId: home.id, harnessId: "codex", title: "Helper" }
    })
  )
  const bot = await run(
    db.createBot({
      id: "bot-helper",
      name: "Helper",
      symbolName: "sparkles",
      slug: "helper",
      projectId: home.id,
      sessionId: "chat-helper",
      workspaceId: "ws-helper",
      projects: [
        { projectId: web.id, folderName: "web", branch: "codevisor/bot-helper" },
        { projectId: api.id, folderName: "api", branch: "codevisor/bot-helper" }
      ]
    })
  )
  return { api, web, home, bot }
}

describe("bots service", () => {
  it("stores a bot with its home project, chat, and ordered repo worktrees", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    const { api, web, home, bot } = await seedBot(db)

    expect(bot).toMatchObject({
      id: "bot-helper",
      serverId: "machine-a",
      name: "Helper",
      symbolName: "sparkles",
      harnessId: "codex",
      projectId: home.id,
      sessionId: "chat-helper",
      workspaceId: "ws-helper",
      rootPath: botPath("helper"),
      projects: [
        { projectId: web.id, folderName: "web", path: join(botPath("helper"), "web") },
        { projectId: api.id, folderName: "api", path: join(botPath("helper"), "api") }
      ]
    })
    expect(await run(db.listBots)).toEqual([bot])
    const projects = await run(db.listProjects)
    expect(projects.find((project) => project.id === home.id)).toMatchObject({
      isBot: true,
      locations: [expect.objectContaining({ isGitRepository: false })]
    })
    expect(projects.find((project) => project.id === api.id)?.isBot).toBeUndefined()
  })

  it("finds the bot that owns a project, workspace, or chat", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    const { api, home } = await seedBot(db)
    const unrelated = await run(db.createProject({ folderPath: "/tmp/bots-unrelated" }))

    for (const query of [
      { projectId: home.id },
      { projectId: api.id },
      { workspaceId: "WS-HELPER" },
      { sessionId: "chat-helper" }
    ]) {
      expect((await run(db.findBotOwning(query)))?.id).toBe("bot-helper")
    }
    expect(await run(db.findBotOwning({ projectId: unrelated.id }))).toBeUndefined()
  })

  it("renames a bot and changes its icon", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    await seedBot(db)

    const renamed = await run(db.updateBot("bot-helper", { name: "Reviewer" }))
    expect(renamed).toMatchObject({ name: "Reviewer", symbolName: "sparkles" })
    expect(renamed.updatedAt).toBeDefined()
    expect(await run(db.updateBot("bot-helper", { symbolName: "ant" }))).toMatchObject({
      name: "Reviewer",
      symbolName: "ant"
    })
    await expect(run(db.updateBot("missing", { name: "Nope" }))).rejects.toThrow(/Bot not found/)
  })

  it("keeps a bot's projects from being deleted until the bot is gone", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    const { api, home } = await seedBot(db)

    await expect(run(db.deleteProject(home.id))).rejects.toThrow(/FOREIGN KEY/)
    await expect(run(db.deleteProject(api.id))).rejects.toThrow(/FOREIGN KEY/)

    await run(db.deleteBot("bot-helper"))
    expect(await run(db.getBot("bot-helper"))).toBeUndefined()
    await run(db.deleteProject(home.id))
    await run(db.deleteProject(api.id))
    expect(await run(db.listBots)).toEqual([])
  })
})

describe("bot workspaces", () => {
  it("attaches workspaces to a bot until the bot is deleted", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    const { api } = await seedBot(db)
    const child = await run(
      db.upsertWorkspace({
        id: "ws-child",
        projectId: api.id,
        name: "Child",
        hasCustomName: false,
        botId: "bot-helper"
      })
    )
    const retried = await run(
      db.upsertWorkspace({ id: "ws-child", projectId: api.id, name: "Child", hasCustomName: true })
    )
    await run(
      db.upsertWorkspace({
        id: "ws-archived",
        projectId: api.id,
        name: "Archived",
        hasCustomName: false,
        isArchived: true,
        botId: "bot-helper"
      })
    )

    expect(child.botId).toBe("bot-helper")
    expect(retried.botId).toBe("bot-helper")
    expect(
      (await run(db.listBotWorkspaces("bot-helper"))).map((workspace) => workspace.id)
    ).toEqual(["ws-child"])

    await run(db.deleteBot("bot-helper"))

    const workspaces = await run(db.listWorkspaces)
    expect(workspaces.find((workspace) => workspace.id === "ws-child")?.botId).toBeUndefined()
    expect(await run(db.listBotWorkspaces("bot-helper"))).toEqual([])
  })

  it("keeps a bot conversation in send order and pages older messages", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    await seedBot(db)

    const first = await run(
      db.appendBotMessage("chat-helper", { id: "m-1", sender: "user", text: "hi" })
    )
    const replay = await run(
      db.appendBotMessage("chat-helper", { id: "m-1", sender: "user", text: "hi again" })
    )
    await run(db.appendBotMessage("chat-helper", { sender: "bot", text: "hello" }))
    await run(db.appendBotMessage("chat-helper", { sender: "notice", text: "rate limited" }))

    expect(first.created).toBe(true)
    expect(replay).toEqual({ message: first.message, created: false })
    const latest = await run(db.listBotMessages("chat-helper", undefined, 2))
    expect(latest.hasMore).toBe(true)
    expect(
      latest.messages.map((message) => [message.sequence, message.sender, message.text])
    ).toEqual([
      [2, "bot", "hello"],
      [3, "notice", "rate limited"]
    ])
    const older = await run(db.listBotMessages("chat-helper", 2, 2))
    expect(older).toEqual({ messages: [first.message], hasMore: false })
  })
})
