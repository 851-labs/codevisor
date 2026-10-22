import type { AgentRuntimeService, LoadedAgentSessionInfo } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { allChats, harnessChats } from "./pause-scope.js"
import { makeMemoryPausedTurnStore } from "./paused-turns.js"
import {
  DRAINED_WITHOUT_RESTART_GRACE_MS,
  makeRestartCoordinator,
  PAUSE_SETTLE_MS
} from "./restart-drain.js"
import { makeMemoryRestartSnapshotStore } from "./restart-snapshot.js"
import { makeEventFanout } from "./server-context.js"
import { idleRouteState, makeServices, run } from "./test-support.js"

const makeWorld = async (loaded: ReadonlyArray<LoadedAgentSessionInfo>) => {
  const { agents, services } = await makeServices("server-a")
  const fanout = await run(makeEventFanout)
  const turns = idleRouteState()
  const snapshot = makeMemoryRestartSnapshotStore()
  const pausedTurns = makeMemoryPausedTurnStore()
  const interrupted: Array<string> = []
  const closed: Array<string> = []
  const logs: Array<string> = []
  const phases: Array<string> = []
  const project = await run(
    services.db.createProject({ folderPath: "/tmp/codevisor-scoped-pause", name: "Repo" })
  )
  const chat = async (harnessId: string, agentSessionId: string) =>
    run(
      services.db.createSession({
        agentSessionId,
        harnessId,
        projectId: project.id,
        title: agentSessionId
      })
    )
  const claude = await chat("claude-code", "agent-claude")
  const codex = await chat("codex", "agent-codex")
  const holdInterrupts = new Set<string>()
  const agentOverrides: Partial<AgentRuntimeService> = {
    cancel: (agentSessionId) =>
      Effect.sync(() => {
        interrupted.push(agentSessionId)
        if (holdInterrupts.has(agentSessionId)) return { runtimeState: "reusable" as const }
        for (const session of [claude, codex]) {
          if (session.agentSessionId === agentSessionId) turns.activeTurnSessions.delete(session.id)
        }
        return { runtimeState: "reusable" as const }
      }),
    closeAgentSession: (agentSessionId) =>
      Effect.sync(() => {
        closed.push(agentSessionId)
      }),
    loadedAgentSessionIds: () => loaded.map((session) => session.sessionId),
    loadedAgentSessions: () => loaded
  }
  const coordinator = makeRestartCoordinator({
    services: { ...services, agents: { ...agents, ...agentOverrides } },
    fanout,
    turns,
    snapshot,
    pausedTurns,
    log: (line) => logs.push(line),
    redrain: async () => {},
    resumePaused: () => {},
    onChange: () => phases.push(describePhase(coordinator.state()))
  })
  return {
    coordinator,
    turns,
    snapshot,
    interrupted,
    closed,
    logs,
    phases,
    holdInterrupts,
    sessions: { claude, codex }
  }
}

const describePhase = (state: {
  readonly state: string
  readonly harnessIds?: ReadonlyArray<string> | undefined
}): string =>
  `${state.state}${state.harnessIds === undefined ? "" : ` ${state.harnessIds.join("+")}`}`

describe("pausing chats for a harness update", () => {
  beforeEach(() => vi.useFakeTimers({ toFake: ["Date", "setTimeout", "clearTimeout"] }))
  afterEach(() => vi.useRealTimers())

  it("pauses and restarts only that harness's chats, keeping ones that can't resume", async () => {
    const world = await makeWorld([
      { sessionId: "agent-claude", harnessId: "claude-code", resumable: true },
      { sessionId: "agent-claude-acp", harnessId: "claude-code", resumable: false },
      { sessionId: "agent-codex", harnessId: "codex", resumable: true }
    ])
    world.turns.activeTurnSessions.add(world.sessions.claude.id)
    world.turns.activeTurnSessions.add(world.sessions.codex.id)

    const paused = await world.coordinator.begin(harnessChats(["claude-code"]))

    expect(paused).toMatchObject({
      state: "drained",
      harnessIds: ["claude-code"],
      harnessNames: { "claude-code": "Claude Code" },
      remaining: 0
    })
    expect(world.interrupted).toEqual(["agent-claude"])
    expect(world.closed).toEqual(["agent-claude"])
    expect(world.snapshot.read()).toBeUndefined()
    expect(world.logs).toContain(
      "Paused chats for the harness update: closed 1, kept 1 that can't resume"
    )
    expect(world.coordinator.gates("claude-code")).toBe(true)
    expect(world.coordinator.gates("codex")).toBe(false)
    expect(world.coordinator.gates(undefined)).toBe(false)
    expect(world.coordinator.gateFor("claude-code")).toEqual({
      harnessId: "claude-code",
      harnessName: "Claude Code"
    })
    expect(world.coordinator.gateFor("retired-harness")).toEqual({
      harnessId: "retired-harness",
      harnessName: "retired-harness"
    })
    world.coordinator.extendGrace()
    await vi.advanceTimersByTimeAsync(DRAINED_WITHOUT_RESTART_GRACE_MS)
    expect(world.coordinator.state().state).toBe("drained")
  })

  it("widens to every chat for a restart, pausing the rest without re-pausing the first", async () => {
    const world = await makeWorld([
      { sessionId: "agent-claude", harnessId: "claude-code", resumable: true },
      { sessionId: "agent-codex", harnessId: "codex", resumable: true }
    ])
    world.turns.activeTurnSessions.add(world.sessions.claude.id)
    world.turns.activeTurnSessions.add(world.sessions.codex.id)
    await world.coordinator.begin(harnessChats(["claude-code"]))

    await expect(world.coordinator.begin(harnessChats(["claude-code"]))).resolves.toMatchObject({
      state: "drained"
    })
    const restart = await world.coordinator.begin(allChats)

    expect(restart).toMatchObject({ state: "drained" })
    expect(restart.harnessIds).toBeUndefined()
    expect(world.interrupted).toEqual(["agent-claude", "agent-codex"])
    expect(world.snapshot.read()).toEqual([])
    expect(world.coordinator.gateFor("claude-code").harnessName).toBe("Codevisor")
    await vi.advanceTimersByTimeAsync(DRAINED_WITHOUT_RESTART_GRACE_MS - 1)
    world.coordinator.extendGrace()
    await vi.advanceTimersByTimeAsync(DRAINED_WITHOUT_RESTART_GRACE_MS - 1)
    expect(world.coordinator.state().state).toBe("drained")
    await vi.advanceTimersByTimeAsync(1)
    expect(world.coordinator.state().state).toBe("idle")
  })

  it("widens a pause that is still settling and only reports the wider pause as done", async () => {
    const world = await makeWorld([])
    world.holdInterrupts.add("agent-claude")
    world.turns.activeTurnSessions.add(world.sessions.claude.id)

    const first = world.coordinator.begin(harnessChats(["claude-code"]))
    await vi.advanceTimersByTimeAsync(250)
    expect(world.coordinator.state()).toMatchObject({ state: "draining", remaining: 1 })
    const second = world.coordinator.begin(harnessChats(["codex"]))
    world.turns.activeTurnSessions.delete(world.sessions.claude.id)
    await vi.advanceTimersByTimeAsync(PAUSE_SETTLE_MS)

    await expect(second).resolves.toMatchObject({
      state: "drained",
      harnessIds: ["claude-code", "codex"]
    })
    await expect(first).resolves.toMatchObject({ state: "drained" })
    expect(world.phases).not.toContain("drained claude-code")
    expect(world.phases.at(-1)).toBe("drained claude-code+codex")
  })

  it("continues every chat once when cancelled while a widened pause waits its turn", async () => {
    const world = await makeWorld([])
    world.holdInterrupts.add("agent-claude")
    world.turns.activeTurnSessions.add(world.sessions.claude.id)

    const first = world.coordinator.begin(harnessChats(["claude-code"]))
    await vi.advanceTimersByTimeAsync(250)
    const widened = world.coordinator.begin(allChats)
    await world.coordinator.cancel()

    await expect(first).resolves.toMatchObject({ state: "idle" })
    await expect(widened).resolves.toMatchObject({ state: "idle" })
    expect(world.interrupted).toEqual(["agent-claude"])
    expect(world.phases.at(-1)).toBe("idle")
  })
})
