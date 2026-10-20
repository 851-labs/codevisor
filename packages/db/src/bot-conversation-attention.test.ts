import type { AttachmentRef, BotMessageSender } from "@codevisor/api"
import { describe, expect, it, onTestFinished } from "vitest"

import { botPath, makeDatabase, type CodevisorDatabaseService } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const openDatabase = async (): Promise<CodevisorDatabaseService> => {
  const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "machine-a" }))
  onTestFinished(() => run(db.close))
  return db
}

const seedChat = async (db: CodevisorDatabaseService, conversational: boolean) => {
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
      conversational,
      projects: []
    })
  )
  return "chat-helper"
}

const deliver = async (
  db: CodevisorDatabaseService,
  sessionId: string,
  sender: BotMessageSender,
  text: string,
  attachments?: ReadonlyArray<AttachmentRef>
) => {
  const { message } = await run(
    db.appendBotMessage(sessionId, { sender, text, ...(attachments ? { attachments } : {}) })
  )
  await run(db.appendEvent("bot.message", sessionId, { message }))
}

const runTurn = async (
  db: CodevisorDatabaseService,
  sessionId: string,
  ended: Record<string, unknown> = { stopReason: "end_turn" }
) => {
  await run(
    db.appendEvent("session.updated", sessionId, {
      initiatedBy: "agent",
      turnId: "turn",
      turnState: "started"
    })
  )
  await run(
    db.appendEvent("session.output", sessionId, { role: "assistant", text: "done", turnId: "turn" })
  )
  await run(
    db.appendEvent("session.updated", sessionId, {
      initiatedBy: "agent",
      turnId: "turn",
      turnState: "ended",
      ...ended
    })
  )
}

const attention = async (db: CodevisorDatabaseService, sessionId: string) => {
  const summary = await run(db.getSessionSummary(sessionId))
  return {
    sidebarState: summary.sidebarState,
    unreadCount: summary.unreadCount,
    hasUnreadError: summary.hasUnreadError,
    latestAttentionSequence: summary.latestAttentionSequence,
    latestBotMessage: summary.latestBotMessage
  }
}

describe("bot conversation attention", () => {
  it("keeps a silent bot turn read and idle", async () => {
    const db = await openDatabase()
    const chat = await seedChat(db, true)

    await runTurn(db, chat)

    expect(await attention(db, chat)).toEqual({
      sidebarState: "idle",
      unreadCount: 0,
      hasUnreadError: false,
      latestAttentionSequence: 0,
      latestBotMessage: undefined
    })
    expect(await run(db.listPendingAttentionSettles)).toEqual([])
  })

  it("makes each message the bot sends unread, with a preview of the latest", async () => {
    const db = await openDatabase()
    const chat = await seedChat(db, true)
    const file: AttachmentRef = {
      fileId: "file-1",
      name: "notes.txt",
      mimeType: "text/plain",
      sizeBytes: 13,
      kind: "file"
    }

    await deliver(db, chat, "user", "how did the release go?")
    await deliver(db, chat, "bot", "Checking now")
    await deliver(db, chat, "bot", "Shipped", [file])
    await runTurn(db, chat)

    expect(await attention(db, chat)).toEqual({
      sidebarState: "unread",
      unreadCount: 2,
      hasUnreadError: false,
      latestAttentionSequence: 2,
      latestBotMessage: { text: "Shipped", attachmentNames: ["notes.txt"] }
    })
  })

  it("clears unread once the latest message is seen", async () => {
    const db = await openDatabase()
    const chat = await seedChat(db, true)
    await deliver(db, chat, "bot", "Shipped")

    await run(db.markSessionRead(chat, 1))

    expect(await attention(db, chat)).toMatchObject({ sidebarState: "idle", unreadCount: 0 })
  })

  it("surfaces a failed turn only through the notice it posts", async () => {
    const db = await openDatabase()
    const chat = await seedChat(db, true)

    await runTurn(db, chat, { stopReason: "refusal", stopDetail: "Usage limit reached" })
    await run(db.appendEvent("session.error", chat, { message: "harness crashed" }))
    expect(await attention(db, chat)).toMatchObject({
      sidebarState: "idle",
      unreadCount: 0,
      hasUnreadError: false
    })

    await deliver(db, chat, "notice", "Couldn't reply: harness crashed")
    expect(await attention(db, chat)).toMatchObject({
      sidebarState: "unread",
      unreadCount: 1,
      hasUnreadError: false,
      latestBotMessage: { text: "Couldn't reply: harness crashed", attachmentNames: [] }
    })
  })

  it("leaves a bot chat outside conversation mode on turn attention", async () => {
    const db = await openDatabase()
    const chat = await seedChat(db, false)

    await runTurn(db, chat)

    expect(await attention(db, chat)).toMatchObject({ sidebarState: "unread", unreadCount: 1 })
  })
})
