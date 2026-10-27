import type { SessionSummary, TranscriptBodyPage } from "@codevisor/api"
import Database from "better-sqlite3"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { integer, rowReader } from "./row-reader.js"
import { run, tempDatabase } from "./test-support.js"

const StatePayload = Schema.Struct({
  sessionUpdate: Schema.optional(Schema.String),
  statePosition: Schema.Number
})
const payload = (entry: { payload: unknown }) =>
  Schema.decodeUnknownSync(StatePayload)(entry.payload)
const live = (event: { payload: unknown }) => payload(event).statePosition
const recordOf = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null ? Object.fromEntries(Object.entries(value)) : {}

const setupQuestions = (questionId: string, presentation?: string) => [
  { id: questionId, question: "Set up", options: [], allowsOther: false, presentation }
]

describe("persisted transcript state", () => {
  it("pages Unicode text and merged tool state after the source events are unavailable", async () => {
    const filename = tempDatabase()
    let session: SessionSummary
    let text: string
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/state-pages" }))
      session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
      text = "a".repeat(8191) + "😀" + "b".repeat(60_000)
      await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
      for (const chunk of [text.slice(0, 9000), text.slice(9000)]) {
        await run(
          db.appendEvent("session.output", session.id, {
            sessionUpdate: "agent_message_chunk",
            messageId: "answer",
            content: { type: "text", text: chunk }
          })
        )
      }
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "tool_call",
          toolCallId: "read",
          title: "Read file",
          rawInput: { path: "notes.txt" },
          status: "in_progress"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "tool_call_update",
          toolCallId: "read",
          status: "completed",
          rawOutput: { text: "preserved output" }
        })
      )
      await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))
      const page = await run(db.getTranscriptPage(session.id, undefined, 8))
      const itemId = page.items[0]!.id
      expect(page.items[0]!.textResource?.fields[0]).toMatchObject({
        pageCount: 9,
        sizeBytes: text.length * 2
      })
      const raw = new Database(filename)
      try {
        raw.exec("delete from session_events")
      } finally {
        raw.close()
      }
      const details = (await run(db.getTranscriptItemDetails(session.id, itemId)))!
      expect(Buffer.byteLength(JSON.stringify(details))).toBeLessThan(100 * 1024)
      expect(details.entries[0]!.payload).toMatchObject({
        sessionUpdate: "agent_message_patch",
        offset: 0,
        text: text.slice(0, 24_000),
        detailResource: { entryKey: "message::answer", itemId }
      })
      expect(details.entries[1]!.payload).toMatchObject({
        sessionUpdate: "tool_call",
        toolCallId: "read",
        title: "Read file",
        isSnapshot: true,
        rawInput: { path: "notes.txt" },
        status: "completed",
        rawOutput: { text: "preserved output" }
      })
      let position: number | undefined = 0
      let reconstructed = ""
      do {
        const body: TranscriptBodyPage = (await run(
          db.getTranscriptBodyPage(session.id, itemId, "message::answer", "text", position)
        ))!
        reconstructed += body.text
        position = body.nextPosition
      } while (position !== undefined)
      expect(reconstructed).toBe(text)
    } finally {
      await run(db.close)
    }
    const restarted = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      expect(
        (await run(restarted.getTranscriptPage(session.id, undefined, 8))).items[0]!.text
      ).toBe(text.slice(0, 24_000))
    } finally {
      await run(restarted.close)
    }
  })

  it("positions answered questions between the tool calls around them", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/question-order" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "claude" }))
      const questions = [{ id: "a", question: "Pick one", options: [{ label: "A" }] }]
      const tool = (toolCallId: string) =>
        run(
          db.appendEvent("session.output", session.id, {
            sessionUpdate: "tool_call",
            toolCallId,
            title: toolCallId,
            status: "completed"
          })
        )
      await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
      const before = await tool("before")
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "question",
          questionId: "q",
          questions
        })
      )
      const resolved = await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "question_resolved",
          questionId: "q",
          outcome: "answered",
          questions,
          answers: { a: { answers: ["A"] } }
        })
      )
      const after = await tool("after")
      await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))

      expect(live(resolved)).toBeGreaterThan(live(before))
      expect(live(resolved)).toBeLessThan(live(after))

      const page = await run(db.getTranscriptPage(session.id, undefined, 8))
      const details = (await run(db.getTranscriptItemDetails(session.id, page.items[0]!.id)))!
      const restored = details.entries.find(
        (entry) => payload(entry).sessionUpdate === "question_resolved"
      )!
      expect(payload(restored).statePosition).toBe(live(resolved))
    } finally {
      await run(db.close)
    }
  })

  it("ends the worked section at a setup prompt and starts a new one when work resumes", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/setup-requests" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "claude" }))
      const ask = (questionId: string, presentation?: string) =>
        run(
          db.appendEvent("session.output", session.id, {
            sessionUpdate: "question",
            questionId,
            questions: setupQuestions(questionId, presentation)
          })
        )
      const resolve = (questionId: string, outcome: string, presentation?: string) =>
        run(
          db.appendEvent("session.output", session.id, {
            sessionUpdate: "question_resolved",
            questionId,
            outcome,
            questions: setupQuestions(questionId, presentation)
          })
        )
      await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
      await ask("exit_plan_mode")
      await resolve("exit_plan_mode", "answered")
      await ask("computer", "computerUsePermissions")
      const declined = await resolve("computer", "cancelled", "computerUsePermissions")
      await ask("chrome", "browserExtensionSetup")

      const page = await run(db.getTranscriptPage(session.id, undefined, 8))
      const [first, second] = page.items
      expect(page.items).toHaveLength(2)
      expect(first).toMatchObject({
        isGenerating: false,
        setupRequests: [
          { questionId: "computer", presentation: "computerUsePermissions", outcome: "cancelled" }
        ]
      })
      expect(second).toMatchObject({
        setupRequests: [{ questionId: "chrome", presentation: "browserExtensionSetup" }]
      })
      expect(payload(declined)).toMatchObject({ sessionUpdate: "question_resolved" })
      expect(recordOf(declined.payload).assistantItemId).toBe(second!.id)

      await resolve("chrome", "autoResolved", "browserExtensionSetup")
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "agent_message_chunk",
          messageId: "after",
          content: { type: "text", text: "Opened it." }
        })
      )
      await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))
      const resumed = await run(db.getTranscriptPage(session.id, undefined, 8))
      expect(resumed.items.map((item) => [item.isGenerating, item.text])).toEqual([
        [false, ""],
        [false, ""],
        [false, "Opened it."]
      ])
      expect(resumed.items[1]?.setupRequests).toEqual([
        { questionId: "chrome", presentation: "browserExtensionSetup", outcome: "autoResolved" }
      ])
    } finally {
      await run(db.close)
    }
  })

  it("reads an abandoned setup prompt as declined and keeps when its section ended", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/abandoned-setup" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "claude" }))
      await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "question",
          questionId: "computer",
          questions: [
            {
              id: "computer",
              question: "Allow",
              options: [],
              allowsOther: false,
              presentation: "computerUsePermissions"
            }
          ]
        })
      )
      const asked = (await run(db.getTranscriptPage(session.id, undefined, 8))).items[0]!
      await new Promise((resolve) => setTimeout(resolve, 5))
      await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))

      const abandoned = (await run(db.getTranscriptPage(session.id, undefined, 8))).items[0]!
      expect(asked.setupRequests).toEqual([
        { questionId: "computer", presentation: "computerUsePermissions" }
      ])
      expect(abandoned.setupRequests).toEqual([
        { questionId: "computer", presentation: "computerUsePermissions", outcome: "cancelled" }
      ])
      expect(asked.endedAt).toBeDefined()
      expect(abandoned.endedAt).toBe(asked.endedAt)
    } finally {
      await run(db.close)
    }
  })

  it("keeps a stopped turn closed when its setup prompt is cancelled afterwards", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/stopped-setup" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "claude" }))
      await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "question",
          questionId: "computer",
          questions: setupQuestions("computer", "computerUsePermissions")
        })
      )
      await run(
        db.appendEvent("session.updated", session.id, {
          turnState: "ended",
          stopReason: "cancelled"
        })
      )
      const cancelled = await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "question_resolved",
          questionId: "computer",
          outcome: "cancelled",
          questions: setupQuestions("computer", "computerUsePermissions")
        })
      )

      const page = await run(db.getTranscriptPage(session.id, undefined, 8))
      expect(page.items).toHaveLength(1)
      expect(page.items[0]).toMatchObject({
        isGenerating: false,
        setupRequests: [
          { questionId: "computer", presentation: "computerUsePermissions", outcome: "cancelled" }
        ]
      })
      expect(recordOf(cancelled.payload).assistantItemId).toBeUndefined()
    } finally {
      await run(db.close)
    }
  })

  it("files a subagent's setup prompt with its parent tool without closing the current section", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/subagent-setup" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "claude" }))
      const ask = (questionId: string, parentToolCallId?: string) =>
        run(
          db.appendEvent("session.output", session.id, {
            sessionUpdate: "question",
            questionId,
            questions: setupQuestions(questionId, "computerUsePermissions"),
            ...(parentToolCallId === undefined ? {} : { parentToolCallId })
          })
        )
      await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "tool_call",
          toolCallId: "task",
          title: "Explore",
          kind: "think",
          status: "in_progress"
        })
      )
      await ask("computer")
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "question_resolved",
          questionId: "computer",
          outcome: "answered",
          questions: setupQuestions("computer", "computerUsePermissions")
        })
      )
      await ask("subagent", "task")

      const page = await run(db.getTranscriptPage(session.id, undefined, 8))
      expect(page.items.map((item) => item.isGenerating)).toEqual([false, true])
      expect(page.items[0]?.setupRequests?.map((request) => request.questionId)).toEqual([
        "computer",
        "subagent"
      ])
    } finally {
      await run(db.close)
    }
  })

  it("shows a setup prompt that arrives after the turn ended without reopening the turn", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/late-setup" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "claude" }))
      await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "agent_message_chunk",
          messageId: "work",
          content: { type: "text", text: "Working." }
        })
      )
      await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))
      const [finished] = (await run(db.getTranscriptPage(session.id, undefined, 8))).items
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "question",
          questionId: "late",
          questions: setupQuestions("late", "computerUsePermissions")
        })
      )

      const page = await run(db.getTranscriptPage(session.id, undefined, 8))
      expect(page.pendingQuestion?.questionId).toBe("late")
      expect(page.items).toHaveLength(2)
      expect(page.items[0]).toMatchObject({ id: finished!.id, endedAt: finished!.endedAt })
      expect(page.items[1]).toMatchObject({
        isGenerating: false,
        setupRequests: [{ questionId: "late", presentation: "computerUsePermissions" }]
      })
    } finally {
      await run(db.close)
    }
  })

  it("resumes a committed migration batch without duplicating text", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/state-migration" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
    const itemId = (await run(db.getTranscriptPage(session.id, undefined, 8))).items[0]!.id
    await run(db.close)
    const raw = new Database(filename)
    const count = 600
    const chunk = "abcdef".repeat(2048)
    const insert =
      raw.prepare(`insert into session_events (session_id, revision, server_id, kind, created_at, payload, chat_item_id)
      values (?, ?, 'local', 'session.output', '2026-09-16T00:00:00.000Z', ?, ?)`)
    raw.transaction(() => {
      for (let index = 0; index < count; index++)
        insert.run(
          session.id,
          index + 2,
          JSON.stringify({
            sessionUpdate: "agent_message_chunk",
            messageId: "answer",
            content: { type: "text", text: chunk }
          }),
          itemId
        )
      raw.prepare("update sessions set revision = ? where id = ?").run(count + 1, session.id)
      raw.prepare("delete from backfill_jobs where id = 'persisted-transcript-state-v1'").run()
    })()
    raw.close()
    await expect(
      run(
        makeDatabase({
          filename,
          serverId: "local",
          onDataUpgradeProgress(progress) {
            if (
              progress.id === "persisted-transcript-state-v1" &&
              progress.state === "running" &&
              progress.completed >= 256
            ) {
              throw new Error("simulated interruption after durable checkpoint")
            }
          }
        })
      )
    ).rejects.toThrow("simulated interruption")
    const check = new Database(filename)
    const checkpoint = rowReader({ completed: integer }).one(
      check
        .prepare("select completed from backfill_jobs where id = 'persisted-transcript-state-v1'")
        .get()
    )
    expect(checkpoint.completed).toBeGreaterThanOrEqual(256)
    expect(checkpoint.completed).toBeLessThan(count)
    check.close()
    const migrated = await run(makeDatabase({ filename, serverId: "local" }))
    const verify = new Database(filename)
    const stored = rowReader({ size: integer }).one(
      verify
        .prepare("select sum(length(text)) as size from transcript_text_chunks where item_id = ?")
        .get(itemId)
    )
    expect(stored.size).toBe(count * chunk.length)
    const job = verify
      .prepare(
        "select state, completed, total from backfill_jobs where id = 'persisted-transcript-state-v1'"
      )
      .get()
    expect(job).toEqual({ state: "completed", completed: count + 1, total: count + 1 })
    verify.close()
    await run(migrated.close)
  })
})
