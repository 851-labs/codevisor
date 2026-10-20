import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { PromptInput } from "@codevisor/agent-runtime"
import { PromptAcceptedResponse, decode } from "@codevisor/api"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import { makeEventFanout } from "../server.js"
import {
  idleRouteState,
  jsonRequest,
  makeServices,
  run,
  tempDirs,
  waitFor
} from "../test-support.js"
import { deliverQueuedPrompt } from "./prompt-delivery.js"
import { drainPromptQueue } from "./prompt-queue.js"
import { createFirstSession, setUpWorkspace, type StartedServer } from "./session-test-support.js"

const prompt = async (server: StartedServer, sessionId: string, body: object) =>
  decode(PromptAcceptedResponse)(
    (
      await jsonRequest(server, `/v1/sessions/${sessionId}/prompt`, {
        body: JSON.stringify(body),
        method: "POST"
      })
    ).body
  )

const sendNow = (server: StartedServer, sessionId: string, queueItemId: string | undefined) =>
  jsonRequest(server, `/v1/sessions/${sessionId}/queue/${queueItemId}/send-now`, {
    method: "POST"
  })

const textOf = (input: string | PromptInput): string =>
  typeof input === "string" ? input : input.text

const sessionRunning = async (firstPrompt: string) => {
  const { agents, server, services, workspace } = await setUpWorkspace()
  const session = await createFirstSession(server, workspace)
  const first = await prompt(server, session.id, { text: firstPrompt })
  await waitFor(() => agents.prompts.length === 1)
  const queue = () => run(services.db.listPromptQueue(session.id))
  const steered = () => agents.steers.map(([, input]) => textOf(input))
  const prompted = () => agents.prompts.map(([, input]) => textOf(input))
  return { agents, server, sessionId: session.id, first, queue, steered, prompted }
}

const runningTurn = async () => {
  const { agents, services } = await makeServices("server-a")
  const folder = mkdtempSync(join(tmpdir(), "codevisor-prompt-delivery-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  await run(
    services.db.createWorkspaceWithSession({
      workspace: { id: "ws-chat", projectId: project.id, name: "Chat", hasCustomName: false },
      session: { id: "chat", projectId: project.id, harnessId: "codex", title: "Chat" }
    })
  )
  const state = idleRouteState()
  state.activeTurnSessions.add("chat")
  const fanout = await run(makeEventFanout)
  return { agents, services, state, fanout }
}

describe("prompt delivery", () => {
  it("reports a prompt to an idle session as sent", async () => {
    const { first } = await sessionRunning("prompt until cancelled")

    expect(first.delivered).toBe("sent")
  })

  it("steers into the running turn by default", async () => {
    const { server, sessionId, queue, steered } = await sessionRunning("prompt until cancelled")

    const result = await prompt(server, sessionId, { text: "also check the tests" })

    expect(result.delivered).toBe("steered")
    expect(steered()).toEqual(["also check the tests"])
    expect(await queue()).toEqual([])
  })

  it("holds a queued prompt for after the turn until it is sent now", async () => {
    const { server, sessionId, queue, steered } = await sessionRunning("prompt until cancelled")

    const queued = await prompt(server, sessionId, { text: "next task", delivery: "queue" })
    expect(queued.delivered).toBe("queued")
    expect(steered()).toEqual([])

    const sent = await sendNow(server, sessionId, queued.queueItemId)
    expect(sent.body).toMatchObject({ delivered: "steered", queueItemId: queued.queueItemId })
    expect(steered()).toEqual(["next task"])
    expect(await queue()).toEqual([])
  })

  it("queues a steer the harness declines and runs it first once sent now", async () => {
    const { agents, server, sessionId, prompted } = await sessionRunning("slow prompt")
    await prompt(server, sessionId, { text: "earlier", delivery: "queue" })

    const declined = await prompt(server, sessionId, { text: "urgent" })
    expect(declined).toMatchObject({ delivered: "queued", steerDeclined: true })
    const promoted = await sendNow(server, sessionId, declined.queueItemId)
    expect(promoted.body).toMatchObject({ delivered: "queued", steerDeclined: true })

    agents.releasePrompt()
    await waitFor(() => agents.prompts.length === 3)
    expect(prompted()).toEqual(["slow prompt", "urgent", "earlier"])
  })

  it("sends a declined steer at once when the turn ends while it is declined", async () => {
    const { agents, services, state, fanout } = await runningTurn()
    const item = await run(services.db.createPromptQueueItem("chat", "after the agent's turn"))
    vi.spyOn(agents, "steer").mockImplementation(() =>
      Effect.sync(() => {
        state.activeTurnSessions.delete("chat")
        return false
      })
    )

    const outcome = await deliverQueuedPrompt(
      services,
      fanout,
      state,
      "server-a",
      "chat",
      item.id,
      "steer"
    )

    expect(outcome).toEqual({ delivered: "sent" })
    await drainPromptQueue(services, fanout, state, "server-a", "chat")
    expect(agents.prompts.map(([, input]) => textOf(input))).toEqual(["after the agent's turn"])
  })

  it("rejects sending a prompt that is no longer queued", async () => {
    const { server, sessionId } = await sessionRunning("prompt until cancelled")

    const missing = await sendNow(server, sessionId, "gone")

    expect(missing.status).toBe(404)
  })
})
