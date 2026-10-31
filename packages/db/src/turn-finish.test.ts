import { afterEach, beforeEach, describe, expect, it, onTestFinished, vi } from "vitest"

import { botPath, makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { ATTENTION_SETTLE_GRACE_MS } from "./session-attention.js"
import { run, tempDatabase } from "./test-support.js"

const devServer = {
  backgroundTasks: [
    { id: "shell-1", description: "bun run dev", status: "running", taskType: "shell" }
  ]
}
const subagent = {
  backgroundTasks: [
    { id: "agent-1", description: "Research", status: "running", taskType: "subagent" }
  ]
}

const openDatabase = async (filename = tempDatabase()): Promise<CodevisorDatabaseService> => {
  const db = await run(makeDatabase({ filename, serverId: "machine-a" }))
  onTestFinished(() => run(db.close).catch(() => undefined))
  return db
}

const event = (db: CodevisorDatabaseService, sessionId: string, payload: object) =>
  run(db.appendEvent("session.updated", sessionId, payload))

const startTurn = (db: CodevisorDatabaseService, sessionId: string, turnId: string) =>
  event(db, sessionId, { initiatedBy: "user", turnId, turnState: "started" })

const endTurn = (
  db: CodevisorDatabaseService,
  sessionId: string,
  turnId: string,
  extra: object = {}
) => event(db, sessionId, { stopReason: "end_turn", turnId, turnState: "ended", ...extra })

const plainChat = async (db: CodevisorDatabaseService, folder: string) => {
  const project = await run(db.createProject({ folderPath: folder }))
  return run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))
}

const botWithChild = async (db: CodevisorDatabaseService) => {
  const home = await run(db.createProject({ folderPath: botPath("helper"), name: "Helper" }))
  await run(
    db.createWorkspaceWithSession({
      workspace: { id: "ws-helper", projectId: home.id, name: "Helper", hasCustomName: false },
      session: { id: "chat-helper", projectId: home.id, harnessId: "codex", title: "Helper" }
    })
  )
  await run(
    db.createBot({
      id: "bot-helper",
      name: "Helper",
      symbolName: "sparkles",
      slug: "helper",
      projectId: home.id,
      sessionId: "chat-helper",
      workspaceId: "ws-helper",
      mode: "conversation",
      projects: []
    })
  )
  const child = await run(
    db.createSession({ projectId: home.id, harnessId: "codex", parentSessionId: "chat-helper" })
  )
  return { botSessionId: "chat-helper", child }
}

describe("turn finish", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date("2026-01-01T00:00:00Z"))
  })
  afterEach(() => vi.useRealTimers())

  it("finishes a turn that leaves a dev server running, for the human and for subscribers alike", async () => {
    const db = await openDatabase()
    const chat = await plainChat(db, "/tmp/finish-dev-server")

    await startTurn(db, chat.id, "t-1")
    await event(db, chat.id, devServer)
    const ended = await endTurn(db, chat.id, "t-1")

    expect(await run(db.getSessionSummary(chat.id))).toMatchObject({
      latestAttentionSequence: 1,
      sidebarState: "unread"
    })
    expect(await run(db.getFinishedTurn(chat.id))).toEqual({
      sessionId: chat.id,
      revision: ended.subjectRevision,
      stopReason: "end_turn"
    })
  })

  it("holds the finish for a running subagent and releases it with the unread mark after the grace", async () => {
    const db = await openDatabase()
    const chat = await plainChat(db, "/tmp/finish-subagent")

    await startTurn(db, chat.id, "t-1")
    await event(db, chat.id, subagent)
    await endTurn(db, chat.id, "t-1")
    const held = await run(db.getFinishedTurn(chat.id))
    await event(db, chat.id, { backgroundTasks: [] })
    const beforeGrace = await run(db.settleSessionAttention(chat.id))
    vi.setSystemTime(new Date(Date.now() + ATTENTION_SETTLE_GRACE_MS))
    const settled = await run(db.settleSessionAttention(chat.id))

    expect(held).toBeUndefined()
    expect(beforeGrace.settled).toBe(false)
    expect(settled).toEqual({ settled: true })
    expect((await run(db.getSessionSummary(chat.id))).latestAttentionSequence).toBe(1)
    expect((await run(db.getFinishedTurn(chat.id)))?.stopReason).toBe("end_turn")
  })

  it("waits for queued prompts before finishing", async () => {
    const db = await openDatabase()
    const chat = await plainChat(db, "/tmp/finish-queue")
    const queued = await run(db.createPromptQueueItem(chat.id, "next", []))

    await startTurn(db, chat.id, "t-1")
    await endTurn(db, chat.id, "t-1")
    const whileQueued = await run(db.getFinishedTurn(chat.id))
    await run(db.deletePromptQueueItem(chat.id, queued.id))
    await run(db.settleSessionAttention(chat.id))

    expect(whileQueued).toBeUndefined()
    expect(await run(db.getFinishedTurn(chat.id))).toBeDefined()
  })

  it("finishes a bot's sub-agent for the bot without marking it unread for the human", async () => {
    const db = await openDatabase()
    const { child } = await botWithChild(db)

    await startTurn(db, child.id, "t-1")
    await endTurn(db, child.id, "t-1")

    expect(await run(db.getSessionSummary(child.id))).toMatchObject({
      latestAttentionSequence: 0,
      sidebarState: "idle"
    })
    expect(await run(db.getFinishedTurn(child.id))).toBeDefined()
  })

  it("settles a held bot sub-agent quietly", async () => {
    const db = await openDatabase()
    const { child } = await botWithChild(db)

    await startTurn(db, child.id, "t-1")
    await event(db, child.id, subagent)
    await endTurn(db, child.id, "t-1")
    await event(db, child.id, { backgroundTasks: [] })
    vi.setSystemTime(new Date(Date.now() + ATTENTION_SETTLE_GRACE_MS))
    await run(db.settleSessionAttention(child.id))

    expect(await run(db.getSessionSummary(child.id))).toMatchObject({
      latestAttentionSequence: 0,
      sidebarState: "idle"
    })
    expect(await run(db.getFinishedTurn(child.id))).toBeDefined()
  })

  it("finishes a bot's own turns for anyone subscribed to it", async () => {
    const db = await openDatabase()
    const { botSessionId } = await botWithChild(db)

    await startTurn(db, botSessionId, "t-1")
    await endTurn(db, botSessionId, "t-1")

    expect((await run(db.getFinishedTurn(botSessionId)))?.stopReason).toBe("end_turn")
  })

  it("finishes each turn once, even when the harness reports its end twice", async () => {
    const db = await openDatabase()
    const chat = await plainChat(db, "/tmp/finish-once")

    await startTurn(db, chat.id, "t-1")
    const first = await endTurn(db, chat.id, "t-1")
    await endTurn(db, chat.id, "t-1", { stopReason: "cancelled" })
    const finished = await run(db.getFinishedTurn(chat.id))
    await run(db.markTurnAnnounced(chat.id, first.subjectRevision!))

    expect(finished).toEqual({
      sessionId: chat.id,
      revision: first.subjectRevision,
      stopReason: "end_turn"
    })
    expect(await run(db.getFinishedTurn(chat.id))).toBeUndefined()
  })

  it("keeps a newer finish when an older one is marked announced", async () => {
    const db = await openDatabase()
    const chat = await plainChat(db, "/tmp/finish-newer")

    await startTurn(db, chat.id, "t-1")
    const first = await endTurn(db, chat.id, "t-1")
    await startTurn(db, chat.id, "t-2")
    const second = await endTurn(db, chat.id, "t-2")
    await run(db.markTurnAnnounced(chat.id, first.subjectRevision!))

    expect((await run(db.getFinishedTurn(chat.id)))?.revision).toBe(second.subjectRevision)
  })

  it("finishes a turn that ends without a stop reason", async () => {
    const db = await openDatabase()
    const chat = await plainChat(db, "/tmp/finish-no-reason")

    await startTurn(db, chat.id, "t-1")
    const ended = await event(db, chat.id, { turnId: "t-1", turnState: "ended" })

    expect(await run(db.getFinishedTurn(chat.id))).toEqual({
      sessionId: chat.id,
      revision: ended.subjectRevision
    })
  })

  it("doesn't finish a turn paused for an update", async () => {
    const db = await openDatabase()
    const chat = await plainChat(db, "/tmp/finish-update")

    await startTurn(db, chat.id, "t-1")
    await endTurn(db, chat.id, "t-1", { stopReason: "cancelled", stopKind: "pausedForUpdate" })

    expect(await run(db.getFinishedTurn(chat.id))).toBeUndefined()
    expect(await run(db.getSessionSummary(chat.id))).toMatchObject({
      latestAttentionSequence: 0,
      sidebarState: "idle"
    })
  })

  it("leaves an error to the errored event", async () => {
    const db = await openDatabase()
    const chat = await plainChat(db, "/tmp/finish-error")

    await startTurn(db, chat.id, "t-1")
    await run(db.appendEvent("session.error", chat.id, { message: "boom" }))

    expect(await run(db.getFinishedTurn(chat.id))).toBeUndefined()
    expect((await run(db.getSessionSummary(chat.id))).sidebarState).toBe("errored")
  })

  it("keeps an unannounced finish across a restart", async () => {
    const filename = tempDatabase()
    const db = await openDatabase(filename)
    const chat = await plainChat(db, "/tmp/finish-restart")
    await startTurn(db, chat.id, "t-1")
    await endTurn(db, chat.id, "t-1")
    await run(db.close)

    const reopened = await openDatabase(filename)

    expect(await run(reopened.listFinishedTurns)).toEqual([
      expect.objectContaining({ sessionId: chat.id, stopReason: "end_turn" })
    ])
  })
})
