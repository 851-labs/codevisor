import { TerminalError } from "@codevisor/terminal"
import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import {
  jsonRequest,
  readSseEvents,
  readWebSocketEvents,
  run,
  tempDirs,
  waitFor
} from "../test-support.js"
import { setUpWorkspace, createFirstSession } from "./session-test-support.js"

describe("session action routes", () => {
  it("queues prompts and routes actions, goals, questions, archive, deletion, and replay", async () => {
    const { agents, server, services, workspace, workspaceFolder } = await setUpWorkspace()
    const session = await createFirstSession(server, workspace)
    const legacyRoot = mkdtempSync(join(tmpdir(), "codevisor-server-legacy-"))
    tempDirs.push(legacyRoot)
    const legacyWorkspaceFolder = join(legacyRoot, "legacy-agent-session")
    mkdirSync(legacyWorkspaceFolder)
    const promptCountBeforeReturnedEvents = agents.prompts.length
    const queueEventsBeforeReturnedEvents = (
      await run(services.db.listSubjectEvents(session.id))
    ).filter((event) => event.kind === "session.queue.updated").length
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "returned events" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === promptCountBeforeReturnedEvents + 1)
    expect(
      (await run(services.db.getSessionDetail(session.id))).conversation.map((item) => item.text)
    ).toEqual(expect.arrayContaining(["returned events", "Raw answer without id"]))
    await waitFor(async () => {
      const processing = await run(services.db.listProcessingPromptQueue(session.id))
      const queueEventCount = (await run(services.db.listSubjectEvents(session.id))).filter(
        (event) => event.kind === "session.queue.updated"
      ).length
      return processing.length === 0 && queueEventCount >= queueEventsBeforeReturnedEvents + 2
    })

    const promptCountBeforeSlow = agents.prompts.length
    const queueEventsBeforeSlow = (await run(services.db.listSubjectEvents(session.id))).filter(
      (event) => event.kind === "session.queue.updated"
    ).length
    const slowResponse = (
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "slow prompt" }),
        method: "POST"
      })
    ).body as { readonly queueItemId: string }
    expect(slowResponse.queueItemId).toBeTypeOf("string")
    await waitFor(() => agents.prompts.length === promptCountBeforeSlow + 1)
    const immediatePromptQueueEvents = (await run(services.db.listSubjectEvents(session.id)))
      .filter((event) => event.kind === "session.queue.updated")
      .slice(queueEventsBeforeSlow)
    expect(immediatePromptQueueEvents).not.toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          payload: expect.objectContaining({
            queue: expect.arrayContaining([
              expect.objectContaining({ id: slowResponse.queueItemId })
            ])
          })
        })
      ])
    )
    const queuedResponse = (
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "queued original" }),
        method: "POST"
      })
    ).body as { readonly queueItemId: string }
    const removedResponse = (
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "queued remove" }),
        method: "POST"
      })
    ).body as { readonly queueItemId: string }
    expect((await jsonRequest(server, `/v1/sessions/${session.id}/queue`)).body).toMatchObject([
      { id: queuedResponse.queueItemId, text: "queued original" },
      { id: removedResponse.queueItemId, text: "queued remove" }
    ])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/queue`, {
          body: JSON.stringify({
            queueItemIds: [removedResponse.queueItemId, queuedResponse.queueItemId]
          }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject([
      { id: removedResponse.queueItemId, text: "queued remove" },
      { id: queuedResponse.queueItemId, text: "queued original" }
    ])
    expect(
      (
        await jsonRequest(
          server,
          `/v1/sessions/${session.id}/queue/${queuedResponse.queueItemId}`,
          {
            body: JSON.stringify({ text: "queued edited" }),
            method: "PATCH"
          }
        )
      ).body
    ).toMatchObject({ text: "queued edited" })
    expect(
      (
        await jsonRequest(
          server,
          `/v1/sessions/${session.id}/queue/${removedResponse.queueItemId}`,
          { method: "DELETE" }
        )
      ).status
    ).toBe(204)
    const promptCountBeforeQueueDrain = agents.prompts.length
    await waitFor(() => agents.prompts.length === promptCountBeforeQueueDrain + 1)
    expect(agents.prompts).toContainEqual([session.agentSessionId, "queued edited"])
    expect(agents.prompts).not.toContainEqual([session.agentSessionId, "queued remove"])

    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "prompt fails" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(async () =>
      (await run(services.db.listSubjectEvents(session.id))).some(
        (event) => event.kind === "session.error"
      )
    )
    expect(agents.loads).toContainEqual(["codex", session.agentSessionId, workspaceFolder])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/connect`, {
          method: "POST"
        })
      ).body
    ).toMatchObject({
      configOptions: [
        {
          currentValue: "gpt-current",
          id: "model",
          options: [{ value: "gpt-current" }, { value: "gpt-new" }]
        }
      ],
      sessionId: session.agentSessionId
    })
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/cancel`, {
          body: JSON.stringify({ clientActionId: "cancel-retry-1" }),
          method: "POST"
        })
      ).status
    ).toBe(202)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/cancel`, {
          body: JSON.stringify({ clientActionId: "cancel-retry-1" }),
          method: "POST"
        })
      ).status
    ).toBe(202)
    expect(agents.cancellations).toEqual([session.agentSessionId])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/mode`, {
          body: JSON.stringify({ modeId: "plan" }),
          method: "POST"
        })
      ).body
    ).toEqual({ modeId: "plan" })
    expect(agents.modes).toEqual([[session.agentSessionId, "plan"]])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
          body: JSON.stringify({ configId: "model", value: "gpt-5" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ configId: "model", configOptions: [{ id: "model" }] })
    expect(agents.configs).toEqual([[session.agentSessionId, "model", "gpt-5"]])

    // Goal set: the double-option tokenBudget key only forwards when present.
    const goalResponse = await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
      body: JSON.stringify({ clientActionId: "goal-1", objective: "ship it", tokenBudget: 50000 }),
      method: "POST"
    })
    expect(goalResponse.status).toBe(202)
    expect(goalResponse.body).toMatchObject({
      objective: "ship it",
      status: "active",
      tokenBudget: 50000
    })
    expect(agents.goals).toEqual([
      [session.agentSessionId, { objective: "ship it", tokenBudget: 50000 }]
    ])
    // Idempotent replay: the same clientActionId returns the stored result
    // without re-invoking the runtime.
    const goalReplay = await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
      body: JSON.stringify({ clientActionId: "goal-1", objective: "ship it", tokenBudget: 50000 }),
      method: "POST"
    })
    expect(goalReplay.status).toBe(202)
    expect(agents.goals).toHaveLength(1)
    // Pause keeps the budget key off the wire entirely.
    await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
      body: JSON.stringify({ status: "paused" }),
      method: "POST"
    })
    expect(agents.goals.at(-1)).toEqual([session.agentSessionId, { status: "paused" }])
    // Explicit null clears the budget.
    await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
      body: JSON.stringify({ tokenBudget: null }),
      method: "POST"
    })
    expect(agents.goals.at(-1)).toEqual([session.agentSessionId, { tokenBudget: null }])
    // Bad payloads are rejected before reaching the runtime.
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
          body: JSON.stringify({ status: "someday" }),
          method: "POST"
        })
      ).status
    ).toBe(400)
    // Runtime failures (e.g. goals unsupported by the harness) surface as errors.
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
          body: JSON.stringify({ objective: "goal fails" }),
          method: "POST"
        })
      ).status
    ).toBeGreaterThanOrEqual(400)
    // Clear.
    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/goal`, { method: "DELETE" })).status
    ).toBe(204)
    expect(agents.goalClears).toEqual([session.agentSessionId])

    // Question answers route to the runtime, with idempotent replay.
    const answerBody = {
      answers: { approach: { answers: ["MVP first"], note: "keep it lean" } },
      clientActionId: "answer-1",
      outcome: "answered"
    }
    const answerResponse = await jsonRequest(
      server,
      `/v1/sessions/${session.id}/questions/q-1/answer`,
      {
        body: JSON.stringify(answerBody),
        method: "POST"
      }
    )
    expect(answerResponse.status).toBe(202)
    expect(answerResponse.body).toEqual({ outcome: "answered", questionId: "q-1" })
    await jsonRequest(server, `/v1/sessions/${session.id}/questions/q-1/answer`, {
      body: JSON.stringify(answerBody),
      method: "POST"
    })
    expect(agents.questionAnswers).toEqual([
      [
        session.agentSessionId,
        "q-1",
        {
          answers: { approach: { answers: ["MVP first"], note: "keep it lean" } },
          outcome: "answered"
        }
      ]
    ])
    // Cancel outcome forwards without answers.
    await jsonRequest(server, `/v1/sessions/${session.id}/questions/q-2/answer`, {
      body: JSON.stringify({ outcome: "cancelled" }),
      method: "POST"
    })
    expect(agents.questionAnswers.at(-1)).toEqual([
      session.agentSessionId,
      "q-2",
      { outcome: "cancelled" }
    ])
    // Bad payloads 400 before reaching the runtime; stale questions surface errors.
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/questions/q-3/answer`, {
          body: JSON.stringify({ outcome: "maybe" }),
          method: "POST"
        })
      ).status
    ).toBe(400)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/questions/stale-question/answer`, {
          body: JSON.stringify({ outcome: "answered" }),
          method: "POST"
        })
      ).status
    ).toBeGreaterThanOrEqual(400)

    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}`, {
          body: JSON.stringify({ title: "Retitled" }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ isArchived: false, title: "Retitled" })
    // Retitling never touches the runtime.
    expect(agents.closes).toEqual([])

    // Archiving retires the runtime: the agent session closes and its
    // background-task terminals (and only those) are killed and removed.
    const backgroundProcess = { killCount: 0 }
    const backgroundTerminal = services.terminal.registerExternalTerminal(
      { sessionId: `${session.agentSessionId}:bg:tool-1` },
      {
        kill: () => {
          backgroundProcess.killCount += 1
        },
        resize: () => undefined,
        write: () => undefined
      }
    )
    const unrelatedTerminal = services.terminal.registerExternalTerminal(
      { sessionId: "other-session:bg:tool-9" },
      { kill: () => undefined, resize: () => undefined, write: () => undefined }
    )
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}`, {
          body: JSON.stringify({ isArchived: true }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ isArchived: true })
    expect(agents.closes).toEqual([session.agentSessionId])
    expect(backgroundProcess.killCount).toBe(1)
    await expect(
      run(services.terminal.terminalFrames(backgroundTerminal.terminalId))
    ).rejects.toBeInstanceOf(TerminalError)
    expect(await run(services.terminal.terminalFrames(unrelatedTerminal.terminalId))).toEqual([])

    // A session with no runtime identity archives without touching the runtime.
    const runtimelessSession = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          agentSessionId: "",
          harnessId: "codex",
          projectId: workspace.id,
          title: "Imported"
        }),
        method: "POST"
      })
    ).body as { readonly id: string }
    await jsonRequest(server, `/v1/sessions/${runtimelessSession.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(agents.closes).toEqual([session.agentSessionId])
    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}`, { method: "DELETE" })).status
    ).toBe(204)
    expect(
      (await jsonRequest(server, `/v1/projects/${workspace.id}`, { method: "DELETE" })).status
    ).toBe(204)

    expect((await readSseEvents(server, 1)).at(0)).toEqual(
      expect.objectContaining({ kind: "project.created" })
    )
    expect((await readSseEvents(server, 1, "not-a-number")).at(0)).toEqual(
      expect.objectContaining({ kind: "project.created" })
    )
    const replayEvents = await run(services.db.listEvents(0))
    const replayEventCount = replayEvents.length
    const replayCursor = replayEvents.at(-1)?.id ?? 0
    const events = await readSseEvents(server, replayEventCount, 0)
    expect(events).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: "project.created" }),
        expect.objectContaining({ kind: "project.deleted" }),
        expect.objectContaining({ kind: "session.created" }),
        expect.objectContaining({ kind: "session.deleted" })
      ])
    )

    const liveEvent = readSseEvents(server, 1, replayCursor)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/live" }),
      method: "POST"
    })
    expect(await liveEvent).toEqual([expect.objectContaining({ kind: "project.created" })])
    const websocketReplay = await readWebSocketEvents(server, 2, 0)
    expect(websocketReplay).toEqual([
      expect.objectContaining({ kind: "project.created" }),
      expect.objectContaining({ kind: "project.updated" })
    ])
    const socketReplayEvents = await run(services.db.listEvents(0))
    const socketReplayCursor = socketReplayEvents.at(-1)?.id ?? 0
    const websocketLive = readWebSocketEvents(server, 1, socketReplayCursor)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/live-socket" }),
      method: "POST"
    })
    expect(await websocketLive).toEqual([expect.objectContaining({ kind: "project.created" })])

    const legacyWorkspace = await run(
      services.db.createProject({ folderPath: legacyWorkspaceFolder })
    )
    const legacySession = await run(
      services.db.createSession({
        harnessId: "codex",
        id: "legacy-session",
        title: "Legacy session",
        projectId: legacyWorkspace.id
      })
    )
    expect(legacySession.agentSessionId).toBeUndefined()
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${legacySession.id}/prompt`, {
          body: JSON.stringify({ text: "legacy hello" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: legacySession.id })
    await waitFor(() => agents.prompts.some((prompt) => prompt[1] === "legacy hello"))
    expect(agents.prompts).toContainEqual([legacySession.id, "legacy hello"])
    expect(agents.loads).toContainEqual(["codex", legacySession.id, legacyWorkspaceFolder])
  })
})
