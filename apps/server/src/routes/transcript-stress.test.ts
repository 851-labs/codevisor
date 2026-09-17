import type { TranscriptBodyPage } from "@codevisor/api"
import { afterEach, expect, it, vi } from "vitest"

import { jsonRequest, run } from "../test-support.js"
import { createFirstSession, setUpWorkspace } from "./session-test-support.js"

afterEach(() => vi.unstubAllEnvs())

it("keeps the transcript driver opt-in and limits mutations to its own fixtures", async () => {
  vi.stubEnv("TRANSCRIPT_STRESS", "0")
  const { server, services, workspace, workspaceFolder } = await setUpWorkspace()
  const post = (body: unknown) =>
    jsonRequest(server, "/dev/transcript-stress", {
      method: "POST",
      body: JSON.stringify(body)
    })
  expect((await post({ action: "seed" })).status).toBe(404)
  vi.stubEnv("TRANSCRIPT_STRESS", "1")
  const ordinary = await createFirstSession(server, workspace)
  expect((await post({ action: "finish", sessionId: ordinary.id })).status).toBe(400)
  const seeded = await post({
    action: "seed",
    folderPath: workspaceFolder,
    turns: 2,
    text: "Fixture **text**"
  })
  expect(seeded.status).toBe(201)
  const { sessionId } = seeded.body as { sessionId: string }
  expect((await post({ action: "compaction", sessionId })).status).toBe(400)
  for (const status of ["started", "completed", "started", "failed"]) {
    expect((await post({ action: "compaction", sessionId, status })).status).toBe(200)
  }
  const compactions = (await run(services.db.listSubjectEvents(sessionId)))
    .filter(
      (event) =>
        (event.payload as { sessionUpdate?: string }).sessionUpdate === "context_compaction"
    )
    .map((event) => event.payload)
  expect(compactions).toMatchObject(
    ["started", "completed", "started", "failed"].map((status) => ({
      sessionUpdate: "context_compaction",
      compactionId: "stress-compaction",
      status
    }))
  )
  expect((await post({ action: "chunk", sessionId, text: "Visible " })).status).toBe(200)
  expect((await post({ action: "chunk", sessionId, text: "append" })).status).toBe(200)
  expect((await post({ action: "finish", sessionId })).status).toBe(200)
  expect(
    (await run(services.db.getSessionDetail(sessionId))).conversation.map((item) => item.text)
  ).toEqual(expect.arrayContaining(["Fixture **text**", "Visible append"]))
  expect((await post({ action: "chunk", sessionId, text: "after finish" })).status).toBe(400)
})

it("rejects browser requests and invalid fixture parameters before creating history", async () => {
  vi.stubEnv("TRANSCRIPT_STRESS", "1")
  const { server, services, workspaceFolder } = await setUpWorkspace()
  const before = await run(services.db.listEvents(0))
  const requests: RequestInit[] = [
    { method: "GET" },
    { method: "POST", headers: { Origin: "http://localhost" }, body: "{}" },
    ...[0, 10_001, 1.5].map((turns) => ({
      method: "POST",
      body: JSON.stringify({ action: "seed", folderPath: workspaceFolder, turns })
    })),
    { method: "POST", body: JSON.stringify({ action: "seed", turns: 1 }) },
    { method: "POST", body: JSON.stringify({ action: "finish" }) }
  ]
  const responses = await Promise.all(
    requests.map((request) => jsonRequest(server, "/dev/transcript-stress", request))
  )
  expect(responses.map((response) => response.status)).toEqual([403, 403, 400, 400, 400, 400, 400])
  expect(await run(services.db.listEvents(0))).toEqual(before)
})

it("defaults to 500 completed turns followed by one controllable live turn", async () => {
  vi.stubEnv("TRANSCRIPT_STRESS", "1")
  const { server, services, agents, workspaceFolder } = await setUpWorkspace()
  const seeded = await jsonRequest(server, "/dev/transcript-stress", {
    method: "POST",
    body: JSON.stringify({
      action: "seed",
      folderPath: workspaceFolder,
      title: "Default-count fixture",
      text: "Small text keeps this count test inexpensive."
    })
  })
  expect(seeded.status).toBe(201)
  expect(seeded.body).toMatchObject({ turns: 500 })
  const { sessionId } = seeded.body as { sessionId: string }
  const detail = await run(services.db.getSessionDetail(sessionId))
  expect(detail.session.title).toBe("Default-count fixture")
  const all = []
  let before: number | undefined
  do {
    const page = await run(services.db.getTranscriptPage(sessionId, before, 64))
    all.unshift(...page.items)
    before = page.nextBefore === undefined ? undefined : Number(page.nextBefore)
  } while (before !== undefined)
  expect(detail.conversation.length).toBeLessThanOrEqual(8)
  expect(all.filter((item) => item.role === "assistant" && !item.isGenerating)).toHaveLength(500)
  expect(all.filter((item) => item.role === "user")).toHaveLength(501)
  expect(detail.conversation.at(-2)?.text).toBe("Live stress stream")
  expect(detail.conversation.at(-1)).toMatchObject({
    role: "assistant",
    text: "",
    isGenerating: true
  })
  expect(agents.prompts).toEqual([])
  expect(
    (
      await jsonRequest(server, "/dev/transcript-stress", {
        method: "POST",
        body: JSON.stringify({ action: "finish", sessionId })
      })
    ).status
  ).toBe(200)
})

it("seeds mixed Markdown and preserves provider text-part identities and phases", async () => {
  vi.stubEnv("TRANSCRIPT_STRESS", "1")
  const { server, services, workspaceFolder } = await setUpWorkspace()
  const post = (body: unknown) =>
    jsonRequest(server, "/dev/transcript-stress", {
      method: "POST",
      body: JSON.stringify(body)
    })
  const seeded = await post({ action: "seed", folderPath: workspaceFolder, turns: 1 })
  expect(seeded.status).toBe(201)
  const { sessionId } = seeded.body as { sessionId: string }
  const detail = await run(services.db.getSessionDetail(sessionId))
  expect(detail.session.title).toBe("Transcript stress")
  const page = await run(services.db.getTranscriptPage(sessionId, undefined, 64))
  const assistant = page.items.find((item) => item.role === "assistant")!
  expect(assistant.text.length).toBeLessThanOrEqual(24_000)
  const resource = assistant.textResource as { itemId: string; entryKey: string }
  let markdown = ""
  let position: number | undefined = 0
  do {
    const body: TranscriptBodyPage = (await run(
      services.db.getTranscriptBodyPage(
        sessionId,
        resource.itemId,
        resource.entryKey,
        "text",
        position
      )
    ))!
    markdown += body.text
    position = body.nextPosition
  } while (position !== undefined)
  expect(markdown).toContain("## Turn 1:")
  expect(markdown).toContain("Paragraph 12.")
  expect(markdown).toContain('let value119 = "Line 119 in turn 1"')
  expect(markdown).toContain("| 79 | **553** |")
  expect(markdown).toContain("> 24. Nested list item")
  expect(markdown).toContain("emoji 👩🏽‍💻 and 日本語")
  expect(
    (
      await post({
        action: "chunk",
        sessionId,
        messageId: "planning",
        phase: "commentary",
        text: "Plan"
      })
    ).status
  ).toBe(200)
  expect(
    (
      await post({
        action: "chunk",
        sessionId,
        messageId: "answer",
        phase: "final",
        text: "Answer"
      })
    ).status
  ).toBe(200)
  expect(
    (await post({ action: "chunk", sessionId, messageId: "answer", phase: "final" })).status
  ).toBe(200)
  const events = await run(services.db.listSubjectEvents(sessionId))
  const chatItemId = detail.conversation.at(-1)!.id
  expect(
    events
      .filter((event) => event.kind === "session.output")
      .slice(-3)
      .map((event) => event.payload)
  ).toMatchObject([
    {
      chatItemId,
      messageId: "planning",
      phase: "commentary",
      sessionUpdate: "agent_message_patch",
      text: "Plan",
      offset: 0
    },
    {
      chatItemId,
      messageId: "answer",
      phase: "final",
      sessionUpdate: "agent_message_patch",
      text: "Answer",
      offset: 0
    },
    {
      chatItemId,
      messageId: "answer",
      phase: "final",
      sessionUpdate: "agent_message_patch",
      text: "",
      offset: 6
    }
  ])
  expect((await post({ action: "finish", sessionId })).status).toBe(200)
})
