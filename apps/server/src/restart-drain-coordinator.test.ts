import { Effect } from "effect"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import { makeMemoryRestartSnapshotStore, makeRestartCoordinator } from "./restart-drain.js"
import { resumeSessionsAfterRestart } from "./restart-resume.js"
import { makeEventFanout } from "./server-context.js"
import { idleRestartCoordinator, makeServices, run } from "./test-support.js"

/// The coordinator's edge paths, driven directly: interruption when a
/// harness will not cancel, snapshot selection, abandonment mid-drain, and
/// the grace period after a drain nobody restarted.

const makeHarness = async () => {
  const { agents, services } = await makeServices("server-a")
  const fanout = await run(makeEventFanout)
  const turns = {
    activePromptSessions: new Set<string>(),
    activeTurnSessions: new Set<string>(),
    restartHeldSessions: new Set<string>()
  }
  const snapshot = makeMemoryRestartSnapshotStore()
  const logs: Array<string> = []
  const redrained: Array<string> = []
  // Two durable sessions: one archived, one whose agent id is still empty.
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
  await run(services.db.updateSession(archived.id, { isArchived: true }))
  return {
    agents,
    services,
    fanout,
    turns,
    snapshot,
    logs,
    redrained,
    sessions: { live, fresh, archived },
    make: (
      overrides: Partial<AgentRuntimeService> = {},
      options: { drainedGraceMs?: number; defaultTimeoutMs?: number } = {}
    ) =>
      makeRestartCoordinator({
        services: { ...services, agents: { ...agents, ...overrides } },
        fanout,
        turns,
        snapshot,
        log: (line) => logs.push(line),
        redrain: async (sessionId) => {
          redrained.push(sessionId)
        },
        ...options
      })
  }
}

describe("restart coordinator", () => {
  beforeEach(() => vi.useFakeTimers({ toFake: ["Date", "setTimeout", "clearTimeout"] }))
  afterEach(() => vi.useRealTimers())
  it("snapshots live, held, and loaded sessions — never archived ones", async () => {
    const harness = await makeHarness()
    const { sessions, turns } = harness
    turns.restartHeldSessions.add(sessions.fresh.id)
    const coordinator = harness.make({
      loadedAgentSessionIds: () => ["agent-live", "agent-old", sessions.fresh.id]
    })

    const drained = await coordinator.begin()

    expect(drained.state).toBe("drained")
    expect(harness.snapshot.read()).toEqual([sessions.fresh.id, sessions.live.id].toSorted())
    expect(harness.agents.closes).toEqual(["agent-live", "agent-old", sessions.fresh.id])
    // Idempotent once drained.
    expect((await coordinator.begin()).state).toBe("drained")
    coordinator.close()
  })

  it("interrupts at the deadline and tolerates harnesses that refuse", async () => {
    const harness = await makeHarness()
    const { sessions, turns } = harness
    turns.activeTurnSessions.add(sessions.live.id)
    // A session that never got an agent id is cancelled under its own id.
    turns.activeTurnSessions.add(sessions.fresh.id)
    turns.activePromptSessions.add("vanished-session")
    let closeAttempts = 0
    const cancelled: Array<string> = []
    const coordinator = harness.make({
      cancel: (agentSessionId) =>
        Effect.promise(async () => {
          // The live turns end on cancel; the vanished one has no row and
          // throws before it gets here.
          cancelled.push(agentSessionId)
          if (agentSessionId === "agent-live") turns.activeTurnSessions.delete(sessions.live.id)
          if (agentSessionId === sessions.fresh.id) {
            turns.activeTurnSessions.delete(sessions.fresh.id)
          }
          return { runtimeState: "reusable" as const }
        }),
      closeAgentSession: () =>
        Effect.promise(async () => {
          closeAttempts += 1
          throw new Error("already gone")
        }),
      loadedAgentSessionIds: () => ["agent-live"]
    })

    const started = coordinator.begin({ timeoutMs: 20 })
    await vi.advanceTimersByTimeAsync(19)
    expect(cancelled).toEqual([])
    expect(coordinator.state()).toMatchObject({ state: "draining", remaining: 3 })
    await vi.advanceTimersByTimeAsync(16_000)
    const drained = await started
    expect(drained.state).toBe("drained")
    expect(cancelled.toSorted()).toEqual(["agent-live", sessions.fresh.id].toSorted())
    expect(harness.logs.some((line) => line.includes("could not cancel vanished-session"))).toBe(
      true
    )
    expect(closeAttempts).toBe(1)
    expect(harness.logs.some((line) => line.includes("could not close agent-live"))).toBe(true)
    // The prompt drain that never ended is left for reconciliation; the
    // snapshot still names its session so the next boot brings it back.
    expect(harness.snapshot.read()).toContain(sessions.live.id)
    coordinator.close()
    turns.activePromptSessions.clear()
  })

  it("interrupts immediately when asked to", async () => {
    const harness = await makeHarness()
    const { sessions, turns } = harness
    turns.activeTurnSessions.add(sessions.live.id)
    const coordinator = harness.make({
      cancel: () =>
        Effect.sync(() => {
          turns.activeTurnSessions.delete(sessions.live.id)
          return { runtimeState: "reusable" as const }
        })
    })
    const draining = coordinator.begin({ interrupt: true, timeoutMs: 60_000 })
    await vi.advanceTimersByTimeAsync(250)
    const drained = await draining
    expect(drained.state).toBe("drained")
    coordinator.close()
  })

  it("a cancel while waiting for interrupted turns abandons the drain", async () => {
    const harness = await makeHarness()
    const { sessions, turns } = harness
    turns.activeTurnSessions.add(sessions.live.id)
    turns.restartHeldSessions.add(sessions.fresh.id)
    // Cancel is accepted but the turn never ends: the settle wait runs
    // until the coordinator is cancelled underneath it.
    const coordinator = harness.make({
      cancel: () => Effect.succeed({ runtimeState: "reusable" as const })
    })
    const started = coordinator.begin({ timeoutMs: 10 })
    await vi.advanceTimersByTimeAsync(250)
    expect(harness.logs.some((line) => line.includes("interrupting 1 live turn"))).toBe(true)
    const cancelled = await coordinator.cancel()
    expect(cancelled.state).toBe("idle")
    await vi.advanceTimersByTimeAsync(250)
    expect((await started).state).toBe("idle")
    expect(harness.snapshot.read()).toBeUndefined()
    // The held session was released and re-drained.
    expect(harness.redrained).toEqual([sessions.fresh.id])
    expect(turns.restartHeldSessions.size).toBe(0)
    coordinator.close()
    turns.activeTurnSessions.clear()
  })

  it("a cancel during finalization does not mark the server drained", async () => {
    const harness = await makeHarness()
    const closing = Promise.withResolvers<void>()
    const releaseClose = Promise.withResolvers<void>()
    const coordinator = harness.make({
      loadedAgentSessionIds: () => ["agent-live"],
      closeAgentSession: () =>
        Effect.promise(() => {
          closing.resolve()
          return releaseClose.promise
        })
    })
    const started = coordinator.begin()
    await closing.promise
    await coordinator.cancel()
    releaseClose.resolve()
    expect((await started).state).toBe("idle")
    expect(coordinator.isGated()).toBe(false)
    coordinator.close()
  })

  it("a snapshot naming only gone or archived sessions resumes nothing", async () => {
    const harness = await makeHarness()
    harness.snapshot.write([harness.sessions.archived.id, "no-such-session"])
    const resumed = await resumeSessionsAfterRestart(
      harness.services,
      harness.fanout,
      {
        ...harness.turns,
        gatedSessions: new Map(),
        pendingPromptActions: new Set(),
        pendingSessionCreates: new Map(),
        turnHeldSessions: new Set(),
        updateSignature: {},
        restart: idleRestartCoordinator()
      },
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
    const coordinator = harness.make({}, { drainedGraceMs: 20 })
    expect((await coordinator.begin()).state).toBe("drained")
    expect(coordinator.isGated()).toBe(true)
    await vi.advanceTimersByTimeAsync(20)
    expect(coordinator.state().state).toBe("idle")
    expect(harness.logs.some((line) => line.includes("never restarted"))).toBe(true)
    // Cancelling again is a no-op; cancelling a drained server clears the timer.
    expect((await coordinator.cancel()).state).toBe("idle")
    const again = harness.make({}, { drainedGraceMs: 60_000 })
    expect((await again.begin()).state).toBe("drained")
    expect((await again.cancel()).state).toBe("idle")
    again.close()
    coordinator.close()
  })
})
