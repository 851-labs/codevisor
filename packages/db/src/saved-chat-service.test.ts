import Database from "better-sqlite3"
import { Effect } from "effect"
import { describe, expect, it, onTestFinished } from "vitest"

import { idRows } from "./common-rows.js"
import { makeDatabase } from "./index.js"
import {
  SAVED_CHAT_FORMAT,
  savedChatChildColumns,
  savedChatItemColumns,
  type SavedChatItem
} from "./saved-chat-service.js"
import { run, tempDatabase } from "./test-support.js"

const columnNamesSql = "select name as id from pragma_table_info(?) order by cid"

const openDatabase = async (serverId: string) => {
  const filename = tempDatabase()
  const db = await run(makeDatabase({ filename, serverId }))
  return { db, filename }
}

const talkedIn = async (db: Awaited<ReturnType<typeof openDatabase>>["db"]) => {
  const project = await run(db.createProject({ folderPath: "/tmp/saved-chat" }))
  const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
  const append = (kind: "session.output" | "session.updated", payload: object) =>
    run(db.appendEvent(kind, session.id, payload))
  await append("session.output", { role: "user", messageId: "ask", startsTurn: true, text: "hi" })
  await append("session.updated", { turnId: "t1", turnState: "started" })
  await append("session.output", {
    sessionUpdate: "tool_call",
    toolCallId: "search",
    title: "search",
    kind: "fetch",
    status: "completed"
  })
  await append("session.output", {
    sessionUpdate: "agent_message_chunk",
    messageId: "reply",
    content: { type: "text", text: "Hello there." }
  })
  await append("session.updated", { stopReason: "end_turn", turnId: "t1", turnState: "ended" })
  return session
}

const savedItemsOf = async (
  db: Awaited<ReturnType<typeof openDatabase>>["db"],
  sessionId: string
): Promise<ReadonlyArray<SavedChatItem>> => {
  const saved: Array<SavedChatItem> = []
  for (const itemId of await run(db.listChatItemIds(sessionId))) {
    saved.push(await run(db.exportChatItem(itemId)))
  }
  return saved
}

const restoreAt = (minute: string, lines: ReadonlyArray<string>) => ({
  startedAt: `2026-11-16T00:0${minute}:00.000Z`,
  completedAt: `2026-11-16T00:0${minute}:40.000Z`,
  lines
})

describe("a chat saved from one server and put back on another", () => {
  it("shows the same conversation and details there, with nothing added", async () => {
    const source = await openDatabase("sandbox-before")
    const target = await openDatabase("sandbox-after")
    try {
      const chat = await talkedIn(source.db)
      const saved = await savedItemsOf(source.db, chat.id)
      const project = await run(target.db.createProject({ folderPath: "/tmp/restored-chat" }))
      const restored = await run(
        target.db.createSession({ id: chat.id, projectId: project.id, harnessId: "codex" })
      )

      for (const item of saved) await run(target.db.importChatItem(restored.id, item))
      await run(target.db.finishChatImport(restored.id, []))

      const before = await run(source.db.getTranscriptPage(chat.id, undefined, 8))
      const after = await run(target.db.getTranscriptPage(restored.id, undefined, 8))
      expect(after.items).toEqual(before.items)
      const reply = before.items[1]!
      const detailsAfter = await run(target.db.getTranscriptItemDetails(restored.id, reply.id))
      const detailsBefore = await run(source.db.getTranscriptItemDetails(chat.id, reply.id))
      expect(detailsAfter?.entries).toEqual(detailsBefore?.entries)
      expect(detailsAfter?.entries.length).toBeGreaterThan(0)
    } finally {
      await Effect.runPromise(source.db.close)
      await Effect.runPromise(target.db.close)
    }
  })

  it("keeps a line for each restore after the last message it brought back, across a later restore", async () => {
    const source = await openDatabase("sandbox-before")
    const second = await openDatabase("sandbox-second")
    const third = await openDatabase("sandbox-third")
    const putBack = async (
      from: typeof source,
      to: typeof source,
      chatId: string,
      restore: ReturnType<typeof restoreAt>
    ) => {
      const project = await run(to.db.createProject({ folderPath: "/tmp/restored-chat" }))
      await run(to.db.createSession({ id: chatId, projectId: project.id, harnessId: "codex" }))
      for (const item of await savedItemsOf(from.db, chatId))
        await run(to.db.importChatItem(chatId, item))
      await run(to.db.finishChatImport(chatId, [], restore))
    }
    try {
      const chat = await talkedIn(source.db)
      const before = await run(source.db.getTranscriptPage(chat.id, undefined, 8))

      await putBack(
        source,
        second,
        chat.id,
        restoreAt("1", ["==> Creating the sandbox", "Left out big.bin"])
      )
      await run(
        second.db.appendEvent("session.output", chat.id, {
          role: "user",
          messageId: "8f5d2c1e-3b4a-4c6d-9e7f-0a1b2c3d4e5f",
          startsTurn: true,
          text: "still there?"
        })
      )
      await putBack(second, third, chat.id, restoreAt("5", ["==> Booting the sandbox"]))

      const after = await run(third.db.getTranscriptPage(chat.id, undefined, 8))
      expect(after.items.map((item) => item.text)).toEqual(["hi", "Hello there.", "still there?"])
      expect(after.items.slice(0, 2)).toEqual(before.items)
      expect(after.setupActivities).toEqual([
        expect.objectContaining({
          kind: "sandbox.restore",
          state: "completed",
          createdAt: "2026-11-16T00:01:00.000Z",
          durationMs: 40_000,
          afterItemId: before.items[1]!.id,
          lines: ["==> Creating the sandbox", "Left out big.bin"]
        }),
        expect.objectContaining({
          kind: "sandbox.restore",
          createdAt: "2026-11-16T00:05:00.000Z",
          afterItemId: after.items[2]!.messageId ?? after.items[2]!.id,
          lines: ["==> Booting the sandbox"]
        })
      ])
    } finally {
      for (const opened of [source, second, third]) await Effect.runPromise(opened.db.close)
    }
  })

  it("leaves a chat that had no messages empty", async () => {
    const { db } = await openDatabase("sandbox-after")
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/restored-chat" }))
      const empty = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

      await run(db.finishChatImport(empty.id, []))

      expect((await run(db.getTranscriptPage(empty.id, undefined, 8))).items).toEqual([])
    } finally {
      await Effect.runPromise(db.close)
    }
  })

  it("settles a turn that was still streaming and refuses rows it can't place", async () => {
    const source = await openDatabase("sandbox-before")
    const target = await openDatabase("sandbox-after")
    try {
      const chat = await talkedIn(source.db)
      const [first] = await savedItemsOf(source.db, chat.id)
      if (first === undefined) throw new Error("The chat has no items")
      const project = await run(target.db.createProject({ folderPath: "/tmp/restored-chat" }))
      const restored = await run(
        target.db.createSession({ projectId: project.id, harnessId: "codex" })
      )
      const streaming = { ...first, item: { ...first.item, status: "streaming" } }
      const unknown = { ...first, children: { ...first.children, future_table: [{ id: "x" }] } }

      const refused = await run(target.db.importChatItem(restored.id, unknown)).catch(
        (cause: unknown) => cause
      )
      await run(target.db.importChatItem(restored.id, streaming))

      expect(String(refused)).toContain("A saved chat has rows this server can't place")
      const page = await run(target.db.getTranscriptPage(restored.id, undefined, 8))
      expect(page.items.map((item) => item.isGenerating)).toEqual([false])
    } finally {
      await Effect.runPromise(source.db.close)
      await Effect.runPromise(target.db.close)
    }
  })
})

describe(`saved chat format ${String(SAVED_CHAT_FORMAT)}`, () => {
  it("copies every column of the tables that make up a chat", async () => {
    const { db, filename } = await openDatabase("local")
    await Effect.runPromise(db.close)

    const sqlite = new Database(filename, { readonly: true })
    onTestFinished(() => void sqlite.close())
    const columnsOf = (table: string): ReadonlyArray<string> =>
      idRows.all(sqlite.prepare(columnNamesSql).all(table)).map((row) => row.id)

    expect(columnsOf("chat_items")).toEqual([...savedChatItemColumns])
    for (const [table, columns] of Object.entries(savedChatChildColumns)) {
      expect(columnsOf(table)).toEqual(columns)
    }
  })
})
