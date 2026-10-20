import { AgentRuntimeError, type AgentRuntimeService } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { makeMemoryPausedTurnStore } from "./paused-turns.js"
import {
  DRAINED_WITHOUT_RESTART_GRACE_MS,
  makeMemoryRestartSnapshotStore,
  PAUSE_SETTLE_MS,
  makeRestartCoordinator,
  type RestartSnapshotStore
} from "./restart-drain.js"
import { resumeSessionsAfterRestart } from "./restart-resume.js"
import { makeEventFanout } from "./server-context.js"
import { archiveSessionViaWorkspace, idleRouteState, makeServices, run } from "./test-support.js"

const makeHarness = async () => {
  const { agents, services } = await makeServices("server-a")
  const fanout = await run(makeEventFanout)
  const turns = idleRouteState()
  const snapshot = makeMemoryRestartSnapshotStore()
  const pausedTurns = makeMemoryPausedTurnStore()
  const logs: Array<string> = []
  const redrained: Array<string> = []
  const resumes: Array<ReadonlyArray<string>> = []
  const project = await run(
    services.db.createProject({ folderPath: "/tmp/codevisor-coordinator", name: "Repo" })
  )
  const live = await run(
    services.db.createSession({
      agentSessionId: "agent-live",
      harnessId: "codex",
      projectId: project.id,
      title: "Live"
    })
  )
  const fresh = await run(
    services.db.createSession({
      deferAgentSession: true,
      harnessId: "codex",
      projectId: project.id,
      title: "Fresh"
    })
  )
  const archived = await run(
    services.db.createSession({
      agentSessionId: "agent-old",
      harnessId: "codex",
      projectId: project.id,
      title: "Old"
    })
  )
  await archiveSessionViaWorkspace(services, project.id, archived.id)
  return {
    agents,
    services,
    fanout,
    turns,
    snapshot,
    pausedTurns,
    logs,
    redrained,
    resumes,
    sessions: { live, fresh, archived },
    make: (overrides: Partial<AgentRuntimeService> = {}, store: RestartSnapshotStore = snapshot) =>
      makeRestartCoordinator({
        services: { ...services, agents: { ...agents, ...overrides } },
        fanout,
        turns,
        snapshot: store,
        pausedTurns,
        log: (line) => logs.push(line),
        redrain: async (sessionId) => {
          redrained.push(sessionId)
        },
        resumePaused: () => resumes.push(pausedTurns.read().map((turn) => turn.sessionId))
      })
  }
}

const POLL_STEP_MS = 250

const diskFull = (): never => {
  throw new Error("ENOSPC: no space left on device")
}

describe("restart coordinator", () => {
  beforeEach(() => vi.useFakeTimers({ toFake: ["Date", "setTimeout", "clearTimeout"] }))
  afterEach(() => vi.useRealTimers())
  it.each(["lookup", "issued cancel"])(
    "cancellation during %s never interrupts a later turn",
    async (stage) => {
      const harness = await makeHarness()
      const entered = Promise.withResolvers<void>()
      const release = Promise.withResolvers<void>()
      const { turns, services, sessions, agents } = harness
      turns.activeTurnSessions.add(sessions.live.id)
      turns.activeTurnSessions.add(sessions.fresh.id)
      const summary = services.db.getSessionSummary
      if (stage === "lookup")
        vi.spyOn(services.db, "getSessionSummary").mockImplementation((id) =>
          Effect.andThen(
            Effect.promise(async () => {
              entered.resolve()
              await release.promise
            }),
            summary(id)
          )
        )
      const interrupted: string[] = []
      const coordinator = harness.make({
        cancel: (id) =>
          Effect.promise(async () => {
            interrupted.push(id)
            entered.resolve()
            await release.promise
            return { runtimeState: "reusable" as const }
          })
      })
      const old = coordinator.begin()
      let next: Promise<unknown> | undefined
      try {
        await entered.promise
        const cancelling = coordinator.cancel()
        turns.activeTurnSessions.clear()
        if (stage === "issued cancel") {
          expect(coordinator.isGated()).toBe(true)
          expect(coordinator.cancel()).toBe(cancelling)
          next = coordinator.begin()
        } else {
          await cancelling
          expect(coordinator.isGated()).toBe(false)
        }
        release.resolve()
        await Promise.all([old, cancelling, next])
        expect(interrupted.toSorted()).toEqual(
          stage === "lookup" ? [] : ["agent-live", sessions.fresh.id].toSorted()
        )
        expect(agents.closes).toEqual([])
      } finally {
        release.resolve()
        await Promise.all([old, next])
        coordinator.close()
      }
    }
  )
  it.each(["completion", "failure"] as const)(
    "a cancelled snapshot lookup's late %s cannot abandon its replacement drain",
    async (outcome) => {
      const harness = await makeHarness()
      const entered = Promise.withResolvers<void>()
      const release = Promise.withResolvers<void>()
      let reads = 0
      const coordinator = makeRestartCoordinator({
        services: {
          ...harness.services,
          db: {
            ...harness.services.db,
            listSessionsRequiringResume: Effect.andThen(
              Effect.promise(async () => {
                if (++reads === 1) {
                  entered.resolve()
                  await release.promise
                  if (outcome === "failure") throw new Error("resume lookup failed")
                }
              }),
              harness.services.db.listSessionsRequiringResume
            )
          }
        },
        fanout: harness.fanout,
        turns: harness.turns,
        snapshot: harness.snapshot,
        pausedTurns: harness.pausedTurns,
        redrain: async () => undefined,
        resumePaused: () => undefined,
        log: () => undefined
      })
      const old = coordinator.begin()
      try {
        await entered.promise
        await coordinator.cancel()
        expect(harness.snapshot.read()).toBeUndefined()
        harness.turns.restartHeldSessions.add(harness.sessions.fresh.id)
        vi.spyOn(harness.services.agents, "loadedAgentSessionIds").mockReturnValue([
          "new-live-agent"
        ])
        expect((await coordinator.begin()).state).toBe("drained")
        expect(harness.agents.closes).toEqual(["new-live-agent"])
        release.resolve()
        await old
        expect(coordinator.state().state).toBe("drained")
        expect(coordinator.isGated()).toBe(true)
        expect(harness.snapshot.read()).toEqual([harness.sessions.fresh.id])
        expect(harness.agents.closes).toEqual(["new-live-agent"])
      } finally {
        release.resolve()
        await old.catch(() => undefined)
        coordinator.close()
      }
    }
  )
  it("snapshots held work without reloading idle or archived sessions", async () => {
    const harness = await makeHarness()
    const { sessions, turns } = harness
    turns.restartHeldSessions.add(sessions.fresh.id)
    const coordinator = harness.make({
      loadedAgentSessionIds: () => ["agent-live", "agent-old", sessions.fresh.id]
    })

    const drained = await coordinator.begin()

    expect(drained.state).toBe("drained")
    expect(harness.snapshot.read()).toEqual([sessions.fresh.id])
    expect(harness.agents.closes).toEqual(["agent-live", "agent-old", sessions.fresh.id])
    expect((await coordinator.begin()).state).toBe("drained")
    coordinator.close()
  })

  it("pauses every live turn at once and records which turn it paused", async () => {
    const harness = await makeHarness()
    const { sessions, turns, services } = harness
    await run(
      services.db.appendEvent("session.updated", sessions.live.id, {
        initiatedBy: "user",
        turnId: "turn-live",
        turnState: "started"
      })
    )
    turns.activeTurnSessions.add(sessions.live.id)
    turns.activePromptSessions.add(sessions.fresh.id)
    const cancelled: Array<string> = []
    const coordinator = harness.make({
      cancel: (agentSessionId) =>
        Effect.sync(() => {
          cancelled.push(agentSessionId)
          turns.activeTurnSessions.delete(sessions.live.id)
          turns.activePromptSessions.delete(sessions.fresh.id)
          return { runtimeState: "reusable" as const }
        }),
      loadedAgentSessionIds: () => ["agent-live"]
    })

    const drained = await coordinator.begin()

    expect(drained.state).toBe("drained")
    expect(cancelled.toSorted()).toEqual(["agent-live", sessions.fresh.id].toSorted())
    expect(harness.pausedTurns.read()).toHaveLength(2)
    expect(harness.pausedTurns.read()).toEqual(
      expect.arrayContaining([
        { sessionId: sessions.live.id, turnId: "turn-live", pausedAt: expect.any(String) },
        { sessionId: sessions.fresh.id, pausedAt: expect.any(String) }
      ])
    )
    expect(harness.agents.closes).toEqual(["agent-live"])
    coordinator.close()
  })

  it("tolerates harnesses that refuse to stop and closes them after the settle time", async () => {
    const harness = await makeHarness()
    const { sessions, turns } = harness
    turns.activeTurnSessions.add(sessions.live.id)
    turns.activePromptSessions.add("vanished-session")
    const coordinator = harness.make({
      cancel: () => Effect.fail(new AgentRuntimeError({ message: "busy", operation: "cancel" })),
      closeAgentSession: (agentSessionId) =>
        Effect.sync(() => {
          harness.agents.closes.push(agentSessionId)
          throw new Error("already gone")
        }),
      loadedAgentSessionIds: () => ["agent-live"]
    })

    const started = coordinator.begin()
    expect(coordinator.begin()).toBe(started)
    await vi.advanceTimersByTimeAsync(PAUSE_SETTLE_MS - 1)
    expect(coordinator.state()).toMatchObject({ state: "draining", remaining: 2 })
    expect(harness.agents.closes).toEqual([])
    await vi.advanceTimersByTimeAsync(POLL_STEP_MS)

    expect((await started).state).toBe("drained")
    expect(harness.agents.closes).toEqual(["agent-live"])
    expect(harness.pausedTurns.read().map((turn) => turn.sessionId)).toEqual([sessions.live.id])
    expect(harness.logs.some((line) => line.includes("could not interrupt"))).toBe(true)
    expect(harness.logs.some((line) => line.includes("could not close agent-live"))).toBe(true)
    expect(harness.logs.some((line) => line.includes("could not pause vanished-session"))).toBe(
      true
    )
    coordinator.close()
    turns.activeTurnSessions.clear()
    turns.activePromptSessions.clear()
  })

  it("a cancel while turns are pausing continues them and releases held prompts", async () => {
    const harness = await makeHarness()
    const { sessions, turns } = harness
    turns.activeTurnSessions.add(sessions.live.id)
    turns.restartHeldSessions.add(sessions.fresh.id)
    const coordinator = harness.make({
      cancel: () => Effect.succeed({ runtimeState: "reusable" as const })
    })
    const started = coordinator.begin()
    await vi.advanceTimersByTimeAsync(POLL_STEP_MS)
    expect(harness.logs.some((line) => line.includes("pausing 1 live turn"))).toBe(true)

    const cancelled = await coordinator.cancel()

    expect(cancelled.state).toBe("idle")
    expect((await started).state).toBe("idle")
    expect(harness.snapshot.read()).toBeUndefined()
    expect(harness.redrained).toEqual([sessions.fresh.id])
    expect(harness.resumes).toEqual([[sessions.live.id]])
    expect(turns.restartHeldSessions.size).toBe(0)
    coordinator.close()
    turns.activeTurnSessions.clear()
  })

  it("a cancel during finalization does not mark the server drained", async () => {
    const harness = await makeHarness()
    const closing = Promise.withResolvers<void>()
    const releaseClose = Promise.withResolvers<void>()
    const coordinator = harness.make({
      loadedAgentSessionIds: () => ["agent-live", "agent-next"],
      closeAgentSession: () =>
        Effect.promise(() => {
          closing.resolve()
          return releaseClose.promise
        })
    })
    const started = coordinator.begin()
    await closing.promise
    const cancelled = coordinator.cancel()
    expect(coordinator.cancel()).toBe(cancelled)
    expect(coordinator.isGated()).toBe(true)
    releaseClose.resolve()
    await cancelled
    expect((await started).state).not.toBe("drained")
    expect(coordinator.isGated()).toBe(false)
    coordinator.close()
  })

  it("abandons a drain it cannot snapshot instead of holding prompts forever", async () => {
    const harness = await makeHarness()
    harness.turns.restartHeldSessions.add(harness.sessions.fresh.id)
    const coordinator = harness.make(
      {},
      { read: () => undefined, write: diskFull, clear: diskFull }
    )

    expect((await coordinator.begin()).state).toBe("idle")
    expect(coordinator.isGated()).toBe(false)
    expect(harness.redrained).toEqual([harness.sessions.fresh.id])
    expect(harness.logs).toContain(
      "Restart drain could not finish: ENOSPC: no space left on device"
    )
    coordinator.close()
  })

  it("a snapshot naming only gone or archived sessions resumes nothing", async () => {
    const harness = await makeHarness()
    harness.snapshot.write([harness.sessions.archived.id, "no-such-session"])
    const resumed = await resumeSessionsAfterRestart(
      harness.services,
      harness.fanout,
      harness.turns,
      "server-a",
      harness.snapshot,
      (line) => harness.logs.push(line)
    )
    expect(resumed).toEqual([])
    expect(harness.snapshot.read()).toBeUndefined()
    expect(harness.agents.loads).toEqual([])
  })

  it("abandons a drain the server never followed with a restart", async () => {
    const harness = await makeHarness()
    const coordinator = harness.make()
    expect((await coordinator.begin()).state).toBe("drained")
    expect(coordinator.isGated()).toBe(true)
    await vi.advanceTimersByTimeAsync(DRAINED_WITHOUT_RESTART_GRACE_MS - 1)
    expect(coordinator.state().state).toBe("drained")
    await vi.advanceTimersByTimeAsync(1)
    expect(coordinator.state().state).toBe("idle")
    expect(harness.logs.some((line) => line.includes("never restarted"))).toBe(true)
    expect((await coordinator.cancel()).state).toBe("idle")
    const again = harness.make()
    expect((await again.begin()).state).toBe("drained")
    expect((await again.cancel()).state).toBe("idle")
    again.close()
    coordinator.close()
  })
})
