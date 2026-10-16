import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { listEvents, listSubjectEvents, run, tempDatabase } from "./test-support.js"

const skillsSnapshot = (names: ReadonlyArray<string>) => ({
  invocationPrefix: "/",
  sessionUpdate: "available_skills_update",
  skills: names.map((name) => ({ invocation: `/${name}`, name }))
})

describe("@codevisor/db", () => {
  it("uses monotonic per-session revisions independent of the global event log", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/session-revisions" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
      const initialCursor = await run(db.latestEventCursor)
      expect(initialCursor).toBeGreaterThan(0)

      const first = await run(
        db.appendEvent("session.updated", session.id, { turnState: "started" })
      )
      await run(db.appendEvent("project.updated", project.id, { title: "unrelated" }))
      const second = await run(
        db.appendEvent("session.output", session.id, {
          role: "assistant",
          text: "hello"
        })
      )

      expect(first.subjectRevision).toBe(1)
      expect(first.globalEventId).toBeUndefined()
      expect(second.subjectRevision).toBe(2)
      expect(second.id).toBe(2)
      expect(second.globalEventId).toBeUndefined()
      expect(listSubjectEvents(filename, session.id).map((event) => event.id)).toEqual([1, 2])
      const assistantItem = (await run(db.getTranscriptPage(session.id, undefined, 8))).items.find(
        (item) => item.role === "assistant"
      )
      expect(assistantItem).toBeDefined()
      expect(first.payload).toMatchObject({ chatItemId: assistantItem?.id })
      expect(second.payload).toMatchObject({ chatItemId: assistantItem?.id })
      expect(listSubjectEvents(filename, session.id)[0]?.payload).toMatchObject({
        chatItemId: assistantItem?.id
      })
      expect(
        listEvents(filename)
          .filter((event) => event.kind !== "navigation.changed")
          .map((event) => event.kind)
      ).toEqual(["project.updated"])
      expect(await run(db.latestEventCursor)).toBeGreaterThan(initialCursor)
      expect((await run(db.getTranscriptPage(session.id, undefined, 8))).eventCursor).toBe(2)
    } finally {
      await Effect.runPromise(db.close)
    }
  })

  it("persists detailed session usage into summaries and transcript snapshots", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/session-usage" }))
      const session = await run(
        db.createSession({ projectId: project.id, harnessId: "claude-code" })
      )

      await run(
        db.appendEvent("session.updated", session.id, {
          sessionUpdate: "usage_update",
          inputTokens: 1_200,
          cachedInputTokens: 800,
          outputTokens: 300,
          reasoningOutputTokens: 100,
          totalTokens: 2_300,
          cost: { amount: 0.42, currency: "USD", kind: "reported" }
        })
      )

      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "usage_update",
          cost: { amount: "unknown", currency: 42, kind: "unknown" }
        })
      )

      const usage = {
        inputTokens: 1_200,
        cachedInputTokens: 800,
        outputTokens: 300,
        reasoningOutputTokens: 100,
        totalTokens: 2_300,
        costAmount: 0.42,
        costCurrency: "USD",
        costKind: "reported"
      }
      expect((await run(db.getSessionSummary(session.id))).usage).toMatchObject(usage)
      expect((await run(db.getTranscriptPage(session.id, undefined, 8))).usage).toMatchObject(usage)
    } finally {
      await Effect.runPromise(db.close)
    }
  })

  it("projects alternate event shapes, plans, tools, and failed turns", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/event-shapes" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

      await run(db.appendEvent("session.output", session.id, "ignored non-object payload"))
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "user_message_chunk",
          content: { type: "text", text: "chunked question" },
          messageId: "question-1"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "user_message_chunk",
          text: "without id"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          role: "system",
          text: "system context",
          attachments: []
        })
      )
      await run(
        db.appendEvent("session.updated", session.id, {
          turnId: "turn-routed",
          turnState: "started"
        })
      )
      const streamingPage = await run(db.getTranscriptPage(session.id, undefined, 32))
      expect(streamingPage.items.at(-1)).toMatchObject({
        isGenerating: true,
        text: ""
      })
      expect(streamingPage.items.at(-1)?.planDocument).toBeUndefined()
      await run(
        db.appendEvent("session.updated", session.id, {
          turnId: "turn-routed",
          turnState: "started"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          role: "assistant",
          text: "direct ",
          messageId: "answer-1"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "agent_message_chunk",
          content: { type: "text", text: "thinking" },
          messageId: "commentary-1",
          phase: "commentary"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "agent_message_chunk",
          content: { type: "text", text: "answer" },
          messageId: "answer-2",
          phase: "final"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "agent_message_chunk",
          text: "anonymous answer"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "agent_message_chunk",
          content: { type: "image" }
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "agent_message_chunk",
          content: { type: "text", text: "" },
          messageId: "empty"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "plan_document",
          markdown: "- [ ] ship"
        })
      )
      expect(
        (await run(db.getTranscriptPage(session.id, undefined, 32))).items.at(-1)?.planDocument
      ).toBe("- [ ] ship")
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "tool_call",
          toolCallId: "tool-1",
          text: "tool detail"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "tool_call_update",
          parentToolCallId: "tool-1",
          toolCallId: "tool-child"
        })
      )
      await run(
        db.appendEvent("session.error", session.id, {
          message: "provider failed",
          retryable: true,
          stopReason: "error",
          turnId: "unknown-turn"
        })
      )
      await run(
        db.appendEvent("session.updated", session.id, {
          turnId: "turn-empty",
          turnState: "started"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          sessionUpdate: "agent_message_chunk",
          text: "commentary only",
          phase: "commentary"
        })
      )
      await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))
      await run(db.appendEvent("session.updated", session.id, { turnState: "started" }))
      await run(
        db.appendEvent("session.updated", session.id, {
          stopReason: "manual",
          stopDetail: "manual detail",
          stopKind: "usageLimit"
        })
      )
      await run(db.appendEvent("session.updated", session.id, { turnState: "ended" }))
      await run(
        db.appendEvent("session.created", session.id, {
          id: session.id,
          projectId: project.id
        })
      )
      await run(
        db.appendEvent("session.archived", session.id, {
          id: session.id,
          projectId: project.id
        })
      )
      await run(
        db.appendEvent("session.deleted", session.id, {
          id: session.id,
          projectId: project.id
        })
      )
      await run(db.appendEvent("session.updated", project.id, null))
      await run(db.appendEvent("session.updated", project.id, { id: "metadata-without-project" }))
      await run(db.appendEvent("session.updated", session.id, { id: "metadata-without-project" }))
      await run(db.appendEvent("session.output", "missing-subject", { text: "orphan" }))

      const page = await run(db.getTranscriptPage(session.id, undefined, 32))
      expect(page.items.map((item) => item.role)).toEqual([
        "user",
        "user",
        "assistant",
        "assistant",
        "assistant"
      ])
      expect(page.items[0]?.text).toBe("chunked question")
      expect(page.items[1]?.text).toBe("without id")
      expect(page.items[2]).toMatchObject({
        hasDetails: true,
        isGenerating: false,
        planDocument: "- [ ] ship",
        retryable: true,
        text: "anonymous answer",
        stopDetail: "provider failed",
        stopReason: "error"
      })
      expect(page.items[3]?.text).toBe("")
      expect(page.items[3]?.stopReason).toBeUndefined()
      expect(page.items[2]?.stopKind).toBeUndefined()
      expect(page.items[4]).toMatchObject({
        text: "",
        stopKind: "usageLimit",
        stopReason: "manual"
      })
      expect(await run(db.getSessionSummary(session.id))).toMatchObject({ id: session.id })
      expect(listSubjectEvents(filename, session.id).length).toBeGreaterThan(20)
      expect(listSubjectEvents(filename, project.id).length).toBeGreaterThan(0)
      expect(listSubjectEvents(filename, "missing-subject").length).toBe(1)
    } finally {
      await Effect.runPromise(db.close)
    }
  })

  it("keeps a sign-in stop kind on the ended turn", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/sign-in-stop-kind" }))
      const session = await run(
        db.createSession({ projectId: project.id, harnessId: "claude-code" })
      )
      await run(
        db.appendEvent("session.updated", session.id, { turnId: "t1", turnState: "started" })
      )
      await run(
        db.appendEvent("session.updated", session.id, {
          stopDetail: "Claude isn't signed in. Sign in to continue.",
          stopKind: "authRequired",
          stopReason: "end_turn",
          turnId: "t1",
          turnState: "ended"
        })
      )

      const page = await run(db.getTranscriptPage(session.id, undefined, 8))
      expect(page.items.find((item) => item.role === "assistant")).toMatchObject({
        stopDetail: "Claude isn't signed in. Sign in to continue.",
        stopKind: "authRequired"
      })
    } finally {
      await Effect.runPromise(db.close)
    }
  })

  it("does not project ACP startup metadata as an assistant turn", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/acp-startup-metadata" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "opencode" }))

      await run(
        db.appendEvent("session.output", session.id, {
          availableCommands: [{ description: "Start a new session", name: "new" }],
          sessionUpdate: "available_commands_update"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          currentModeId: "build",
          sessionUpdate: "current_mode_update"
        })
      )

      expect((await run(db.getTranscriptPage(session.id, undefined, 32))).items).toEqual([])

      await run(db.appendEvent("session.output", session.id, { role: "user", text: "hello" }))
      await run(
        db.appendEvent("session.updated", session.id, {
          turnId: "first-turn",
          turnState: "started"
        })
      )
      await run(
        db.appendEvent("session.output", session.id, {
          content: { type: "text", text: "Hello! How can I help?" },
          sessionUpdate: "agent_message_chunk"
        })
      )
      await run(
        db.appendEvent("session.updated", session.id, {
          turnId: "first-turn",
          turnState: "ended"
        })
      )

      expect((await run(db.getTranscriptPage(session.id, undefined, 32))).items).toMatchObject([
        { role: "user", text: "hello" },
        { role: "assistant", text: "Hello! How can I help?" }
      ])
    } finally {
      await run(db.close)
    }
  })

  it("keeps the latest skills snapshot as session state", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      const project = await run(db.createProject({ folderPath: "/tmp/skills-state" }))
      const session = await run(db.createSession({ projectId: project.id, harnessId: "claude" }))
      await run(db.appendEvent("session.output", session.id, skillsSnapshot(["review", "ship"])))
      await run(db.appendEvent("session.output", session.id, skillsSnapshot(["review"])))

      const page = await run(db.getTranscriptPage(session.id, undefined, 32))
      expect(page.items).toEqual([])
      expect(page.stateUpdates).toEqual([])
      expect(page.skills).toEqual({
        invocationPrefix: "/",
        skills: [{ invocation: "/review", name: "review" }]
      })
      expect(await run(db.getSessionSkills(session.id))).toEqual({
        invocationPrefix: "/",
        skills: [{ invocation: "/review", name: "review" }]
      })
    } finally {
      await run(db.close)
    }
  })
})
