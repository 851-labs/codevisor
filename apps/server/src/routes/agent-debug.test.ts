import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { SessionSummary } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { makeEventFanout } from "../server.js"
import { makeServices, run, tempDirs } from "../test-support.js"
import { readAgentItem, searchAgentTranscript } from "./agent-debug.js"
import { agentState } from "./agent-state.js"
import { pageRecordsNewestFirst } from "./agent-transcript.js"
import { agentStatusOf } from "./agents.js"
import { sessionEventSink } from "./session-events.js"

const bigOutput = `${"build log line\n".repeat(6_000)}FAILED: 3 tests`
const longReply = `${"All done. ".repeat(4_000)}The end.`

const seededAgent = async () => {
  const { services } = await makeServices("agent-debug")
  const folder = mkdtempSync(join(tmpdir(), "codevisor-agent-debug-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  const session = await run(
    services.db.createSession({ projectId: project.id, harnessId: "codex" })
  )
  const sink = sessionEventSink(services, await run(makeEventFanout), "agent-debug", session.id)
  const emit = (kind: "session.output" | "session.updated", payload: Record<string, unknown>) =>
    sink({ kind, subjectId: session.id, payload })
  await run(services.db.appendConversationItem(session.id, "user", "ask", "Run the tests", false))
  await emit("session.updated", { initiatedBy: "user", turnId: "turn-1", turnState: "started" })
  await emit("session.output", {
    sessionUpdate: "tool_call",
    toolCallId: "tool-1",
    kind: "execute",
    status: "completed",
    title: "Ran bun test",
    rawInput: { command: "bun test" },
    rawOutput: bigOutput
  })
  await emit("session.output", {
    sessionUpdate: "tool_call",
    toolCallId: "tool-2",
    kind: "read",
    rawInput: { path: "notes.md" }
  })
  await emit("session.output", {
    sessionUpdate: "tool_call",
    toolCallId: "tool-3",
    kind: "edit",
    status: "completed",
    title: "Wrote big.txt",
    rawInput: { path: "big.txt", content: bigOutput }
  })
  await emit("session.output", {
    sessionUpdate: "question",
    questionId: "q-1",
    questions: [{ id: "a", question: "Ship it?", options: [], allowsOther: true }]
  })
  await emit("session.output", {
    sessionUpdate: "plan",
    entries: [{ content: "Run the tests", status: "pending", priority: "medium" }]
  })
  await emit("session.output", {
    sessionUpdate: "agent_message_chunk",
    messageId: "reply-1",
    content: { type: "text", text: longReply }
  })
  await emit("session.updated", {
    initiatedBy: "user",
    turnId: "turn-1",
    turnState: "ended",
    stopReason: "end_turn"
  })
  return { db: services.db, agentId: session.id, services }
}

const historyOf = async (count: number) => {
  const seeded = await seededAgent()
  for (let index = 0; index < count; index += 1) {
    const text = index === 1 ? `${"x".repeat(200)} MIDDLE ${"y".repeat(200)}` : `Message ${index}`
    await run(
      seeded.services.db.appendConversationItem(seeded.agentId, "user", `m-${index}`, text, false)
    )
  }
  return seeded
}

const allFilters = {
  query: undefined,
  kinds: undefined,
  tool: undefined,
  last: 20,
  next: undefined
}

describe("agent debug reads", () => {
  it("finds a tool call by tool and reads its complete output", async () => {
    const { db, agentId } = await seededAgent()

    const hits = await searchAgentTranscript(db, agentId, {
      ...allFilters,
      tool: "bun test",
      query: "failed"
    })

    expect(hits.items).toEqual([
      expect.objectContaining({
        kind: "tool",
        tool: "Ran bun test",
        snippet: expect.stringContaining("FAILED: 3 tests")
      })
    ])
    const item = await readAgentItem(db, agentId, hits.items[0]!.itemId)
    expect(item).toMatchObject({
      kind: "tool",
      status: "completed",
      input: { command: "bun test" }
    })
    expect(item.output).toBe(bigOutput)
  })

  it("lists newest items first by kind and reads a long reply in full", async () => {
    const { db, agentId } = await seededAgent()

    const hits = await searchAgentTranscript(db, agentId, {
      ...allFilters,
      kinds: new Set(["user", "assistant"])
    })

    expect(hits.items.map((hit) => hit.kind)).toEqual(["assistant", "user"])
    expect(hits.items[0]!.snippet.length).toBeLessThan(200)
    expect((await readAgentItem(db, agentId, hits.items[0]!.itemId)).text).toBe(longReply)
    expect((await readAgentItem(db, agentId, hits.items[1]!.itemId)).text).toBe("Run the tests")
  })
})

const summary = (fields: Partial<SessionSummary>): SessionSummary => ({
  id: "agent",
  projectId: "project",
  serverId: "server",
  harnessId: "codex",
  title: "Agent",
  origin: "codevisor",
  createdAt: "2026-10-23T00:00:00.000Z",
  ...fields
})

describe("agent debug paging and errors", () => {
  it("pages hits across transcript pages and resumes from next", async () => {
    const { db, agentId } = await historyOf(20)
    const userOnly = { ...allFilters, kinds: new Set(["user"] as const) }

    const first = await searchAgentTranscript(db, agentId, { ...userOnly, last: 16 })
    const rest = await searchAgentTranscript(db, agentId, {
      ...userOnly,
      last: 16,
      next: first.next
    })

    expect(first.items).toHaveLength(16)
    expect(first.items[0]!.snippet).toBe("Message 19")
    expect(rest.items.map((hit) => hit.snippet)).toEqual([
      "Message 3",
      "Message 2",
      expect.stringMatching(/^x{80}…$/),
      "Message 0",
      "Run the tests"
    ])
    expect(rest.next).toBeUndefined()
    expect(await readAgentItem(db, agentId, rest.items.at(-1)!.itemId)).toMatchObject({
      kind: "user",
      text: "Run the tests"
    })
  })

  it("keeps reading older pages until it has enough hits", async () => {
    const { db, agentId } = await historyOf(20)

    const hits = await searchAgentTranscript(db, agentId, {
      ...allFilters,
      kinds: new Set(["user"] as const),
      last: 18
    })

    expect(hits.items.map((hit) => hit.snippet).slice(-2)).toEqual(["Message 3", "Message 2"])
    expect(hits.next).toEqual(expect.any(String))
  })

  it("centers a snippet on the match", async () => {
    const { db, agentId } = await historyOf(2)

    const hits = await searchAgentTranscript(db, agentId, { ...allFilters, query: "middle" })

    expect(hits.items.map((hit) => hit.snippet)).toEqual([
      expect.stringMatching(/^…x+ MIDDLE y+…$/)
    ])
  })

  it("reads a tool's large input back as the object it was", async () => {
    const { db, agentId } = await seededAgent()

    const [hit] = (await searchAgentTranscript(db, agentId, { ...allFilters, tool: "big.txt" }))
      .items

    expect((await readAgentItem(db, agentId, hit!.itemId)).input).toEqual({
      path: "big.txt",
      content: bigOutput
    })
  })

  it("matches tools by kind and reads one that has no title or status", async () => {
    const { db, agentId } = await seededAgent()

    const hits = await searchAgentTranscript(db, agentId, { ...allFilters, tool: "read" })

    expect(hits.items).toEqual([
      expect.objectContaining({ kind: "tool", snippet: expect.stringContaining("notes.md") })
    ])
    expect(await readAgentItem(db, agentId, hits.items[0]!.itemId)).toEqual({
      itemId: hits.items[0]!.itemId,
      kind: "tool",
      at: expect.any(String),
      input: { path: "notes.md" }
    })
  })

  it("rejects a forged cursor and unknown items", async () => {
    const { db, agentId } = await seededAgent()
    const forged = Buffer.from(JSON.stringify({ skip: -1 })).toString("base64url")
    const [toolHit] = (
      await searchAgentTranscript(db, agentId, { ...allFilters, kinds: new Set(["tool"] as const) })
    ).items
    const itemId = toolHit!.itemId.split(":")[0]!

    await expect(
      searchAgentTranscript(db, agentId, { ...allFilters, next: forged })
    ).rejects.toMatchObject({ status: 400 })
    await expect(readAgentItem(db, agentId, "missing-item")).rejects.toMatchObject({ status: 404 })
    await expect(readAgentItem(db, agentId, `${itemId}:tool:missing`)).rejects.toMatchObject({
      status: 404
    })
    await expect(readAgentItem(db, agentId, `${itemId}:plan`)).rejects.toMatchObject({
      status: 404
    })
  })
})

describe("agent transcript records", () => {
  it("files hidden Codevisor events under the event kind", async () => {
    const { db, agentId } = await seededAgent()
    const event = {
      id: "e-1",
      sessionId: agentId,
      sequence: 9,
      role: "user" as const,
      text: "<codevisor-event>",
      createdAt: "2026-10-23T00:00:00.000Z",
      updatedAt: "2026-10-23T00:00:00.000Z",
      isGenerating: false,
      hasDetails: false,
      origin: "event" as const,
      revision: 1
    }

    const records = await pageRecordsNewestFirst(db, agentId, {
      items: [event],
      hasNewer: false,
      hasMore: false,
      eventCursor: 0,
      stateUpdates: [],
      setupActivities: []
    })

    expect(records.map((record) => record.kind)).toEqual(["event"])
  })
})

describe("agent state", () => {
  const idle = { sidebarState: "idle" } as const satisfies Partial<SessionSummary>

  it("reports the last reply and a pending question only when there are some", () => {
    const question = {
      sessionUpdate: "question" as const,
      questionId: "q-1",
      questions: [{ id: "a", question: "Ship it?", options: [], allowsOther: true }]
    }

    expect(agentStatusOf(summary(idle), {}, false, "")).toEqual({
      agentId: "agent",
      title: "Agent",
      state: "idle"
    })
    expect(agentStatusOf(summary(idle), { pendingQuestion: question }, false, "Done.")).toEqual({
      agentId: "agent",
      title: "Agent",
      state: "waitingForUser",
      lastReply: "Done.",
      pendingQuestion: question
    })
  })

  it("counts an idle agent as working while its turn end waits on background work", () => {
    expect(agentState(summary(idle), {}, false)).toBe("idle")
    expect(agentState(summary(idle), {}, true)).toBe("working")
    expect(agentState(summary({ sidebarState: "errored" }), {}, true)).toBe("errored")
    expect(agentState(summary({ ...idle, actionRequired: true }), {}, true)).toBe("waitingForUser")
  })
})
