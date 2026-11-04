import { steerSettlementEvent, type SteerOutcome } from "@codevisor/agent-runtime"
import { PromptAcceptedResponse, decode } from "@codevisor/api"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import { jsonRequest, run, waitFor } from "../test-support.js"
import { createFirstSession, setUpWorkspace, type StartedServer } from "./session-test-support.js"

const prompt = async (server: StartedServer, sessionId: string, text: string) =>
  decode(PromptAcceptedResponse)(
    (
      await jsonRequest(server, `/v1/sessions/${sessionId}/prompt`, {
        body: JSON.stringify({ text }),
        method: "POST"
      })
    ).body
  )

const nextStepSession = async () => {
  const { agents, server, services, workspace } = await setUpWorkspace()
  const load = agents.loadAgentSession.bind(agents)
  vi.spyOn(agents, "loadAgentSession").mockImplementation((...args) =>
    Effect.map(load(...args), (metadata) => ({ ...metadata, steersAtNextStep: true }))
  )
  const session = await createFirstSession(server, workspace)
  await prompt(server, session.id, "prompt until cancelled")
  await waitFor(() => agents.prompts.length === 1)
  const agentSessionId = agents.prompts[0]![0]
  const settle = (steerId: string, outcome: SteerOutcome) =>
    agents.emit(
      agentSessionId,
      steerSettlementEvent(agentSessionId, { id: steerId, outcome, startsTurn: false })
    )
  const queue = () => run(services.db.listVisiblePromptQueue(session.id))
  const inTranscript = (messageId: string) =>
    run(services.db.hasConversationMessage(session.id, messageId))
  return { agents, server, sessionId: session.id, agentSessionId, settle, queue, inTranscript }
}

describe("messages steered into a harness that reads them at its next step", () => {
  it("waits in the queue as the next step until the harness takes it, then joins the transcript", async () => {
    const { server, sessionId, settle, queue, inTranscript } = await nextStepSession()

    const steered = await prompt(server, sessionId, "make the bot mode a select")

    expect(steered.delivered).toBe("steered")
    expect(await queue()).toMatchObject([{ id: steered.queueItemId, steered: true }])
    expect(await inTranscript(steered.queueItemId!)).toBe(false)

    await settle(steered.queueItemId!, "absorbed")

    expect(await queue()).toEqual([])
    expect(await inTranscript(steered.queueItemId!)).toBe(true)
  })

  it("interrupts only the running step when the harness can, instead of cancelling the turn", async () => {
    const { agents, server, sessionId, agentSessionId } = await nextStepSession()
    const interrupted: Array<string> = []
    Object.assign(agents, {
      interruptStep: (id: string) =>
        Effect.sync(() => {
          interrupted.push(id)
          return true
        })
    })
    const steered = await prompt(server, sessionId, "do this instead")

    await jsonRequest(server, `/v1/sessions/${sessionId}/queue/${steered.queueItemId}/send-now`, {
      method: "POST"
    })

    expect(interrupted).toEqual([agentSessionId])
    expect(agents.cancellations).toEqual([])
  })

  it("cancels the turn when the harness can't interrupt just the step", async () => {
    const { agents, server, sessionId, agentSessionId } = await nextStepSession()
    const steered = await prompt(server, sessionId, "do this instead")

    const sent = await jsonRequest(
      server,
      `/v1/sessions/${sessionId}/queue/${steered.queueItemId}/send-now`,
      { method: "POST" }
    )

    expect(sent.body).toMatchObject({ delivered: "steered", queueItemId: steered.queueItemId })
    expect(agents.cancellations).toEqual([agentSessionId])
  })

  it("returns a steer the harness dropped to the queue as an ordinary queued message", async () => {
    const { server, sessionId, settle, queue, inTranscript } = await nextStepSession()
    const steered = await prompt(server, sessionId, "never read")

    await settle(steered.queueItemId!, "dropped")

    const [item] = await queue()
    expect(item).toMatchObject({ id: steered.queueItemId, text: "never read" })
    expect(item?.steered).toBeUndefined()
    expect(await inTranscript(steered.queueItemId!)).toBe(false)
  })
})
