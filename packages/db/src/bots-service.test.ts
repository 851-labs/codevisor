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
      mascot: { color: "mint", hat: "none", eyewear: "none" },
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

  it("returns the options picked for the bot's chat", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    const { bot } = await seedBot(db)

    expect(bot.configSelections).toBeUndefined()
    await run(db.replaceSessionConfigSelections("chat-helper", { model: "gpt-5", effort: "high" }))

    const picked = { model: "gpt-5", effort: "high" }
    expect((await run(db.getBot("bot-helper")))?.configSelections).toEqual(picked)
    expect((await run(db.listBots)).map((listed) => listed.configSelections)).toEqual([picked])
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

  it("renames a bot and changes its icon and mascot", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    await seedBot(db)
    const mascot = {
      color: "sky",
      hat: "beanie",
      hatColor: "red",
      eyewear: "goggles",
      eyewearColor: "pink"
    }

    const renamed = await run(db.updateBot("bot-helper", { name: "Reviewer" }))
    expect(renamed).toMatchObject({
      name: "Reviewer",
      symbolName: "sparkles",
      mascot: {
        color: "mint",
        hat: "none",
        hatColor: "auto",
        eyewear: "none",
        eyewearColor: "auto"
      }
    })
    expect(renamed.updatedAt).toBeDefined()
    expect(await run(db.updateBot("bot-helper", { symbolName: "ant", mascot }))).toMatchObject({
      name: "Reviewer",
      symbolName: "ant",
      mascot
    })
    expect((await run(db.getBot("bot-helper")))?.mascot).toEqual(mascot)
    await expect(run(db.updateBot("missing", { name: "Nope" }))).rejects.toThrow(/Bot not found/)
  })

  it("keeps an item's color when an update leaves it out, and resets it when the item changes", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    await seedBot(db)
    await run(
      db.updateBot("bot-helper", {
        mascot: {
          color: "sky",
          hat: "beanie",
          hatColor: "red",
          eyewear: "goggles",
          eyewearColor: "pink"
        }
      })
    )

    const updated = await run(
      db.updateBot("bot-helper", { mascot: { color: "lilac", hat: "beanie", eyewear: "specs" } })
    )

    expect(updated.mascot).toEqual({
      color: "lilac",
      hat: "beanie",
      hatColor: "red",
      eyewear: "specs",
      eyewearColor: "auto"
    })
  })

  it("archives and unarchives a bot without touching its other fields", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    await seedBot(db)

    const archived = await run(db.updateBot("bot-helper", { isArchived: true }))

    expect(archived).toMatchObject({ isArchived: true, name: "Helper", symbolName: "sparkles" })
    expect(await run(db.getBot("bot-helper"))).toEqual(archived)
    expect(
      await run(db.updateBot("bot-helper", { isArchived: true, name: "Reviewer" }))
    ).toMatchObject({ isArchived: true, name: "Reviewer" })
    expect((await run(db.updateBot("bot-helper", { symbolName: "ant" }))).isArchived).toBe(true)
    expect(await run(db.updateBot("bot-helper", { isArchived: false }))).toMatchObject({
      isArchived: false,
      name: "Reviewer",
      symbolName: "ant"
    })
  })

  it("appends a project after the bot's others and frees one it removes", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    const { api, web } = await seedBot(db)
    const docs = await run(db.createProject({ folderPath: "/tmp/bots-docs", name: "docs" }))

    const added = await run(
      db.addBotProject("bot-helper", {
        projectId: docs.id,
        folderName: "docs",
        branch: "codevisor/bot-helper"
      })
    )
    const removed = await run(db.removeBotProject("bot-helper", api.id.toUpperCase()))

    expect(added.projects.map((project) => project.folderName)).toEqual(["web", "api", "docs"])
    expect(removed.projects.map((project) => project.projectId)).toEqual([web.id, docs.id])
    expect(removed.updatedAt).toBeDefined()
    expect((await run(db.findBotOwning({ projectId: api.id })))?.id).toBeUndefined()
    await run(db.deleteProject(api.id))
    await expect(
      run(
        db.addBotProject("bot-helper", {
          projectId: web.id,
          folderName: "web-2",
          branch: "codevisor/bot-helper"
        })
      )
    ).rejects.toThrow(/UNIQUE/)
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
  it("resolves a session's bot from its home, its local bot, or a bot on another machine", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    const { api } = await seedBot(db)
    const chatIn = async (id: string, bot: { botId?: string; botMachineId?: string }) => {
      await run(
        db.createWorkspaceWithSession({
          workspace: { id: `ws-${id}`, projectId: api.id, name: id, hasCustomName: false, ...bot },
          session: { id, projectId: api.id, harnessId: "codex", title: id }
        })
      )
    }
    await chatIn("local-child", { botId: "bot-helper" })
    await chatIn("remote-child", {
      botId: "6D1F0C35-2A64-4F3E-9D0A-3B7F3C1C9A10",
      botMachineId: "machine-b"
    })
    await chatIn("plain", {})
    const retried = await run(
      db.upsertWorkspace({
        id: "ws-remote-child",
        projectId: api.id,
        name: "R",
        hasCustomName: true
      })
    )

    expect(await run(db.findBotLinkForSession("chat-helper"))).toEqual({ botId: "bot-helper" })
    expect(await run(db.findBotLinkForSession("local-child"))).toEqual({ botId: "bot-helper" })
    expect(await run(db.findBotLinkForSession("remote-child"))).toEqual({
      botId: "6d1f0c35-2a64-4f3e-9d0a-3b7f3c1c9a10",
      botMachineId: "machine-b"
    })
    expect(retried).toMatchObject({
      botId: "6d1f0c35-2a64-4f3e-9d0a-3b7f3c1c9a10",
      botMachineId: "machine-b"
    })
    expect(await run(db.findBotLinkForSession("plain"))).toBeUndefined()
    expect(await run(db.findBotLinkForSession("missing"))).toBeUndefined()
    expect(await run(db.listBotWorkspaces("6d1f0c35-2a64-4f3e-9d0a-3b7f3c1c9a10"))).toEqual([])
  })

  it("fixes a workspace's link to another machine's bot when the workspace is created", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    const { api } = await seedBot(db)
    const link = (parent: string | undefined, botId = "6d1f0c35-2a64-4f3e-9d0a-3b7f3c1c9a10") =>
      run(
        db.upsertWorkspace({
          id: "ws-linked",
          projectId: api.id,
          name: "Linked",
          hasCustomName: false,
          botId,
          botMachineId: "machine-b",
          ...(parent === undefined ? {} : { botParentSessionId: parent })
        })
      )
    await run(
      db.createWorkspaceWithSession({
        workspace: { id: "ws-unrecorded", projectId: api.id, name: "U", hasCustomName: false },
        session: { id: "unrecorded-chat", projectId: api.id, harnessId: "codex", title: "U" }
      })
    )
    await run(
      db.upsertWorkspace({
        id: "ws-unrecorded",
        projectId: api.id,
        name: "U",
        hasCustomName: false,
        botId: "6d1f0c35-2a64-4f3e-9d0a-3b7f3c1c9a10",
        botMachineId: "machine-b"
      })
    )

    await link("remote:machine-b:bot-chat")
    await link("remote:machine-b:other-chat", "a8a0d4f4-61c4-4a4e-8b1a-4f2f6e7c9b01")

    expect(await run(db.findWorkspaceFleetBotLink("ws-linked"))).toEqual({
      parentSessionId: "remote:machine-b:bot-chat",
      bot: { botId: "6d1f0c35-2a64-4f3e-9d0a-3b7f3c1c9a10", botMachineId: "machine-b" }
    })
    expect(await run(db.findWorkspaceFleetBotLink("ws-unrecorded"))).toBeUndefined()
    const unrecorded = (await run(db.listWorkspaces)).find((w) => w.id === "ws-unrecorded")
    expect(unrecorded?.botId).toBeUndefined()
    expect(await run(db.findFleetBotLink("unrecorded-chat"))).toBeUndefined()
    expect(await run(db.findWorkspaceFleetBotLink("ws-missing"))).toBeUndefined()
    expect(await run(db.findFleetBotLink("missing-chat"))).toBeUndefined()
  })

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

  it("keeps the files a bot attaches to its messages", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    await seedBot(db)
    const shot = {
      fileId: "file-1",
      name: "shot.png",
      mimeType: "image/png",
      sizeBytes: 3,
      kind: "image" as const
    }

    const { message } = await run(
      db.appendBotMessage("chat-helper", { sender: "bot", text: "here", attachments: [shot] })
    )

    expect(message.attachments).toEqual([shot])
    expect((await run(db.listBotMessages("chat-helper", undefined, 10))).messages).toEqual([
      message
    ])
  })
})
