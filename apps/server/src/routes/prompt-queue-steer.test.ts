import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { AgentRuntimeError } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import { makeEventFanout } from "../server.js"
import { idleRouteState, makeServices, run, tempDirs, waitFor } from "../test-support.js"
import { drainPromptQueue } from "./prompt-queue.js"

const liveBotTurn = async () => {
  const { agents, services } = await makeServices("server-a")
  const folder = mkdtempSync(join(tmpdir(), "codevisor-prompt-steer-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  await run(
    services.db.createWorkspaceWithSession({
      workspace: { id: "ws-bot", projectId: project.id, name: "Bot", hasCustomName: false },
      session: { id: "chat-bot", projectId: project.id, harnessId: "codex", title: "Bot" }
    })
  )
  await run(
    services.db.createBot({
      id: "bot-1",
      name: "Bot",
      symbolName: "sparkles",
      slug: "bot",
      projectId: project.id,
      sessionId: "chat-bot",
      workspaceId: "ws-bot",
      conversational: true,
      projects: []
    })
  )
  const state = idleRouteState()
  state.activeTurnSessions.add("chat-bot")
  const fanout = await run(makeEventFanout)
  const drain = () => drainPromptQueue(services, fanout, state, "server-a", "chat-bot")
  return { agents, services, state, drain }
}

describe("steering a bot's running turn", () => {
  it("runs a prompt the harness declined once the turn it raced has ended", async () => {
    const { agents, services, state, drain } = await liveBotTurn()
    await run(services.db.createPromptQueueItem("chat-bot", "also this"))
    vi.spyOn(agents, "steer").mockImplementation(() =>
      Effect.sync(() => {
        state.activeTurnSessions.delete("chat-bot")
        return false
      })
    )

    await drain()

    await waitFor(() =>
      agents.prompts.some(([, input]) => JSON.stringify(input).includes("also this"))
    )
  })

  it("keeps a prompt queued while the turn runs when steering fails", async () => {
    const { agents, services, drain } = await liveBotTurn()
    await run(services.db.createPromptQueueItem("chat-bot", "also this"))
    vi.spyOn(agents, "steer").mockImplementation(() =>
      Effect.fail(new AgentRuntimeError({ message: "turn already over", operation: "steer" }))
    )

    await Promise.all([drain(), drain()])

    expect(agents.prompts).toEqual([])
    expect(await run(services.db.listPromptQueue("chat-bot"))).toMatchObject([
      { text: "also this" }
    ])
  })
})
