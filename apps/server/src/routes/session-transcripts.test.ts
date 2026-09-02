import { describe, expect, it } from "vitest"
import { jsonRequest, readWebSocketEvents, run, waitFor } from "../test-support.js"
import { setUpWorkspace, createFirstSession } from "./session-test-support.js"

describe("session transcript routes", () => {
  it("records prompts, transcripts, history, and scoped event replay", async () => {
    const { agents, server, services, workspace } = await setUpWorkspace()
    const session = await createFirstSession(server, workspace)
    const promptCountBeforeHello = agents.prompts.length
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "hello" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === promptCountBeforeHello + 1)
    expect(agents.prompts).toContainEqual([session.agentSessionId, "hello"])
    const promptCountBeforeRetry = agents.prompts.length
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ clientActionId: "prompt-retry-1", text: "retry once" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ clientActionId: "prompt-retry-1", text: "retry once" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === promptCountBeforeRetry + 1)
    expect(agents.prompts).toEqual(
      expect.arrayContaining([
        [session.agentSessionId, "hello"],
        [session.agentSessionId, "retry once"]
      ])
    )
    const promptCountBeforeRawChunks = agents.prompts.length
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "raw chunks" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === promptCountBeforeRawChunks + 1)
    let rawConversation: ReadonlyArray<string> = []
    let rawEvents: ReadonlyArray<unknown> = []
    await waitFor(
      async () => {
        rawConversation = (await run(services.db.getSessionDetail(session.id))).conversation.map(
          (item) => item.text
        )
        rawEvents = await run(services.db.listSubjectEvents(session.id))
        return rawConversation.includes("Raw answer without id")
      },
      () => JSON.stringify({ rawConversation, rawEvents })
    )
    expect(
      (await run(services.db.getSessionDetail(session.id))).conversation.map((item) => item.text)
    ).toEqual(
      expect.arrayContaining(["hello", "Echo: hello", "raw chunks", "Raw answer without id"])
    )
    expect(await run(services.db.listSubjectEvents(session.id))).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "session.output",
          payload: expect.objectContaining({ sessionUpdate: "agent_message_chunk" })
        })
      ])
    )
    // The per-session history endpoint returns only this session's envelopes.
    const historyResponse = await jsonRequest(server, `/v1/sessions/${session.id}/events`)
    expect(historyResponse.status).toBe(200)
    const history = historyResponse.body as Array<{ subjectId: string; kind: string }>
    expect(history.length).toBeGreaterThan(0)
    expect(history.every((event) => event.subjectId === session.id)).toBe(true)
    const scopedReplay = (await readWebSocketEvents(
      server,
      2,
      0,
      `/v1/sessions/${session.id}/events/socket`
    )) as Array<{ id: number; subjectId: string; subjectRevision?: number }>
    expect(scopedReplay.every((event) => event.subjectId === session.id)).toBe(true)
    expect(scopedReplay.map((event) => event.id)).toEqual([1, 2])
    expect(scopedReplay.map((event) => event.subjectRevision)).toEqual([1, 2])
    const transcriptResponse = await jsonRequest(
      server,
      `/v1/sessions/${session.id}/transcript?limit=2`
    )
    expect(transcriptResponse.status).toBe(200)
    const transcript = transcriptResponse.body as {
      items: Array<{ id: string; role: string; text: string }>
      hasMore: boolean
      eventCursor: number
    }
    expect(transcript.items.length).toBeLessThanOrEqual(2)
    expect(transcript.items.some((item) => item.role === "assistant")).toBe(true)
    expect(transcript.eventCursor).toBeGreaterThan(0)
    expect((await jsonRequest(server, `/v1/sessions/${session.id}/transcript`)).status).toBe(200)
    const assistantTranscriptItem = transcript.items.find((item) => item.role === "assistant")!
    const transcriptDetails = await jsonRequest(
      server,
      `/v1/sessions/${session.id}/transcript/${assistantTranscriptItem.id}/details`
    )
    expect(transcriptDetails.status).toBe(200)
    expect(transcriptDetails.body).toMatchObject({ itemId: assistantTranscriptItem.id })
    expect(
      (
        transcriptDetails.body as {
          events: Array<{ subjectId: string }>
        }
      ).events.every((event) => event.subjectId === session.id)
    ).toBe(true)
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript?before=wat`)
    ).toMatchObject({ status: 400 })
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript?before=-1`)
    ).toMatchObject({ status: 400 })
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript?limit=wat`)
    ).toMatchObject({ status: 400 })
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript?limit=0`)
    ).toMatchObject({ status: 400 })
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript/missing/details`)
    ).toMatchObject({ status: 404 })
    expect(
      await jsonRequest(
        server,
        `/v1/sessions/${session.id}/transcript/${assistantTranscriptItem.id}/details?through=wat`
      )
    ).toMatchObject({ status: 400 })
    expect(
      await jsonRequest(
        server,
        `/v1/sessions/${session.id}/transcript/${assistantTranscriptItem.id}/details?through=-1`
      )
    ).toMatchObject({ status: 400 })
  })
})
