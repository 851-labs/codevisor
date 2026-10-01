import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Effect } from "effect"
import { expect, it, vi } from "vitest"

import { forgetRetiredSessionTurn } from "../server-workspace-effects.js"
import { makeEventFanout, type RouteState } from "../server.js"
import { idleRestartCoordinator, makeServices, run, tempDirs } from "../test-support.js"
import { drainPromptQueue, reconcileStaleStreamingTurns } from "./prompt-queue.js"
import { applySessionConfigPick } from "./session-config.js"
import { ensureAgentSessionFor } from "./session-workspace.js"

const setup = async () => {
  const fixture = await makeServices("server-a")
  const folder = mkdtempSync(join(tmpdir(), "codevisor-session-races-"))
  tempDirs.push(folder)
  const project = await run(fixture.services.db.createProject({ folderPath: folder }))
  const session = await run(
    fixture.services.db.createSession({
      projectId: project.id,
      harnessId: "codex",
      agentSessionId: ""
    })
  )
  const fanout = await run(makeEventFanout)
  const state: RouteState = {
    activePromptSessions: new Set(),
    promptTurnReleases: new Map(),
    activeTurnSessions: new Set(),
    gatedSessions: new Map(),
    pendingPromptActions: new Set(),
    pendingSessionCreates: new Map(),
    turnHeldSessions: new Set(),
    updateSignature: {},
    restartHeldSessions: new Set(),
    restart: idleRestartCoordinator()
  }
  return { ...fixture, session, fanout, state }
}

it("concurrent first opens share one deferred agent", async () => {
  const { services, agents, session, fanout } = await setup()
  const opened = await Promise.all([
    ensureAgentSessionFor(services, fanout, "server-a", session.id),
    ensureAgentSessionFor(services, fanout, "server-a", session.id)
  ])
  expect(agents.creations).toHaveLength(1)
  expect(opened[0]?.sessionId).toBe(opened[1]?.sessionId)
})

it("retirement during a summary lookup cannot release the replacement drain", async () => {
  const { services, agents, session, fanout, state } = await setup()
  await run(services.db.createPromptQueueItem(session.id, "replacement"))
  const entered = Promise.withResolvers<void>()
  const release = Promise.withResolvers<void>()
  const prompting = Promise.withResolvers<void>()
  const finishPrompt = Promise.withResolvers<void>()
  const summary = services.db.getSessionSummary
  let reads = 0
  vi.spyOn(services.db, "getSessionSummary").mockImplementation((id) =>
    Effect.andThen(
      Effect.promise(async () => {
        if (++reads === 1) {
          entered.resolve()
          await release.promise
        }
      }),
      summary(id)
    )
  )
  const prompt = agents.prompt
  vi.spyOn(agents, "prompt").mockImplementation((...args) =>
    Effect.andThen(
      Effect.promise(async () => {
        prompting.resolve()
        await finishPrompt.promise
      }),
      prompt(...args)
    )
  )
  const old = drainPromptQueue(services, fanout, state, "server-a", session.id)
  let replacement: Promise<void> | undefined
  try {
    await entered.promise
    forgetRetiredSessionTurn(state, session.id)
    expect(state.activePromptSessions.has(session.id)).toBe(false)
    replacement = drainPromptQueue(services, fanout, state, "server-a", session.id)
    await prompting.promise
    release.resolve()
    await old
    expect(state.activePromptSessions.has(session.id)).toBe(true)
    finishPrompt.resolve()
    await replacement
    expect(state.activePromptSessions.has(session.id)).toBe(false)
    expect(agents.prompts).toHaveLength(1)
  } finally {
    release.resolve()
    finishPrompt.resolve()
    await Promise.all([old, replacement])
  }
})

it("a missing session releases its dispatch claim after failing", async () => {
  const { services, fanout, state } = await setup()
  await expect(drainPromptQueue(services, fanout, state, "server-a", "missing")).rejects.toThrow()
  expect(state.activePromptSessions.size).toBe(0)
  expect(state.promptTurnReleases.size).toBe(0)
})

it("concurrent deferred picker changes preserve both selections", async () => {
  const { services, session, fanout } = await setup()
  await Promise.all([
    applySessionConfigPick(services, fanout, "server-a", session.id, {
      configId: "model",
      value: "model-saved"
    }),
    applySessionConfigPick(services, fanout, "server-a", session.id, {
      configId: "speed",
      value: "fast"
    })
  ])
  expect(await run(services.db.getSessionConfigSelections(session.id))).toEqual({
    model: "model-saved",
    speed: "fast"
  })
})

it("a second drain cannot dispatch while the first prompt is held", async () => {
  const { services, agents, session, fanout, state } = await setup()
  await run(services.db.createPromptQueueItem(session.id, "first"))
  await run(services.db.createPromptQueueItem(session.id, "second"))
  const entered = Promise.withResolvers<void>()
  const release = Promise.withResolvers<void>()
  const overlapping = Promise.withResolvers<void>()
  const prompt = agents.prompt
  let active = 0
  let maximum = 0
  vi.spyOn(agents, "prompt").mockImplementation((...args) =>
    Effect.andThen(
      Effect.promise(async () => {
        maximum = Math.max(maximum, ++active)
        entered.resolve()
        if (active === 2) overlapping.resolve()
        await release.promise
        active -= 1
      }),
      prompt(...args)
    )
  )
  const first = drainPromptQueue(services, fanout, state, "server-a", session.id)
  const second = drainPromptQueue(services, fanout, state, "server-a", session.id)
  try {
    await entered.promise
    // The second drain returns after publishing its held queue. In the broken
    // implementation it instead owns another prompt, so release both calls.
    await Promise.race([second, overlapping.promise])
    release.resolve()
    await Promise.all([first, second])
    expect(maximum).toBe(1)
    expect(agents.prompts).toHaveLength(2)
  } finally {
    release.resolve()
    await Promise.all([first, second])
  }
})

it("a stale sweep preserves a turn that starts after candidate lookup", async () => {
  const { services, session, fanout, state } = await setup()
  const started = "2026-01-01T00:00:00.000Z"
  vi.useFakeTimers({ toFake: ["Date"] })
  try {
    vi.setSystemTime(started)
    await run(
      services.db.appendEvent("session.output", session.id, { role: "assistant", text: "old" })
    )
    vi.setSystemTime("2026-01-01T00:10:00.000Z")
    const has = state.activePromptSessions.has.bind(state.activePromptSessions)
    let queued = false
    vi.spyOn(state.activePromptSessions, "has").mockImplementation((id) => {
      const live = has(id)
      if (!queued && id === session.id) {
        queued = true
        queueMicrotask(() => {
          state.activeTurnSessions.add(session.id)
          Effect.runSync(
            services.db.appendEvent("session.updated", session.id, {
              turnState: "started",
              turnId: "new"
            })
          )
        })
      }
      return live
    })
    await reconcileStaleStreamingTurns(services, fanout, state, "server-a")
    expect(
      (await run(services.db.getTranscriptPage(session.id, undefined, 1))).items.at(-1)
        ?.isGenerating
    ).toBe(true)
  } finally {
    vi.useRealTimers()
  }
})
