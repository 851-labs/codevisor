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
    expect(archived.archivedAt).toEqual(expect.any(String))
    expect(await run(db.getBot("bot-helper"))).toEqual(archived)
    expect(
      await run(db.updateBot("bot-helper", { isArchived: true, name: "Reviewer" }))
    ).toMatchObject({ isArchived: true, archivedAt: archived.archivedAt, name: "Reviewer" })
    expect((await run(db.updateBot("bot-helper", { symbolName: "ant" }))).isArchived).toBe(true)
    const unarchived = await run(db.updateBot("bot-helper", { isArchived: false }))
    expect(unarchived).toMatchObject({ isArchived: false, name: "Reviewer", symbolName: "ant" })
    expect(unarchived).not.toHaveProperty("archivedAt")
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

  it("ends a bot's conversation with the bot", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    const { home } = await seedBot(db)
    await run(db.appendBotMessage("chat-helper", { sender: "user", text: "remember this" }))

    await run(db.deleteBot("bot-helper"))
    await run(
      db.createBot({
        id: "bot-again",
        name: "Again",
        symbolName: "sparkles",
        mascot: { color: "mint", hat: "none", eyewear: "none" },
        slug: "again",
        projectId: home.id,
        sessionId: "chat-helper",
        workspaceId: "ws-helper",
        projects: []
      })
    )

    expect((await run(db.listBotMessages("chat-helper", undefined, 10))).messages).toEqual([])
  })

  it("copies a conversation to another bot's chat and tells clients to refresh it", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    const { home } = await seedBot(db)
    await seedFork(db, home.id)
    await run(db.appendBotMessage("chat-helper", { sender: "user", text: "ship it" }))
    await run(db.appendBotMessage("chat-helper", { sender: "bot", text: "shipping" }))

    const changes = await run(db.copyBotMessages("chat-helper", "chat-fork"))

    const copied = await run(db.listBotMessages("chat-fork", undefined, 10))
    expect(copied.messages.map((message) => [message.sender, message.text])).toEqual([
      ["user", "ship it"],
      ["bot", "shipping"]
    ])
    expect(changes.map((change) => [change.kind, change.subjectId, change.payload])).toEqual([
      ["navigation.changed", "chat-fork", { table: "sessions" }]
    ])
  })

  it("imports a conversation from another machine with its times and files", async () => {
    useWorktreesRoot()
    const db = await openDatabase()
    const { home } = await seedBot(db)
    await seedFork(db, home.id)
    const file = await run(
      db.createDiskFile({
        id: "file-shot",
        name: "shot.png",
        mimeType: "image/png",
        sizeBytes: 3,
        sha256: "abc",
        kind: "image",
        createdAt: "2026-11-01T00:00:00.000Z"
      })
    )
    const shot = {
      fileId: file.id,
      name: "shot.png",
      mimeType: "image/png",
      sizeBytes: 3,
      kind: "image" as const
    }

    const changes = await run(
      db.importBotMessages("chat-fork", [
        { sender: "user", text: "ship it", createdAt: "2026-11-01T10:00:00.000Z" },
        { sender: "bot", text: "here", attachments: [shot], createdAt: "2026-11-01T10:01:00.000Z" }
      ])
    )
    const imported = await run(db.listBotMessages("chat-fork", undefined, 10))
    await run(db.deleteBot("bot-fork"))
    await run(db.deleteSession("chat-fork"))

    expect(
      imported.messages.map((message) => [
        message.sender,
        message.text,
        message.createdAt,
        message.attachments
      ])
    ).toEqual([
      ["user", "ship it", "2026-11-01T10:00:00.000Z", undefined],
      ["bot", "here", "2026-11-01T10:01:00.000Z", [shot]]
    ])
    expect(changes.map((change) => [change.kind, change.subjectId])).toEqual([
      ["navigation.changed", "chat-fork"]
    ])
    expect(await run(db.getFileMetadata(file.id))).toBeUndefined()
  })
})

const seedFork = async (db: CodevisorDatabaseService, homeProjectId: string) => {
  await run(
    db.createWorkspaceWithSession({
      workspace: { id: "ws-fork", projectId: homeProjectId, name: "Fork", hasCustomName: false },
      session: { id: "chat-fork", projectId: homeProjectId, harnessId: "codex", title: "Fork" }
    })
  )
  await run(
    db.createBot({
      id: "bot-fork",
      name: "Fork",
      symbolName: "sparkles",
      mascot: { color: "mint", hat: "none", eyewear: "none" },
      slug: "fork",
      projectId: homeProjectId,
      sessionId: "chat-fork",
      workspaceId: "ws-fork",
      projects: []
    })
  )
}
