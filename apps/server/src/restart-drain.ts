import type { RestartDrainState } from "@codevisor/api"
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"
import {
  appendAndPublish,
  failureMessage,
  run,
  swallowError,
  type CodevisorServerServices,
  type EventFanout
} from "./server-context.js"

/// The restart drain: how a server restarts (for an update) without killing
/// chats mid-turn.
///
/// `begin` closes a dispatch gate — new prompts are accepted and stay
/// durable in the prompt queue, but nothing is claimed — then waits for
/// every live turn to end. When the deadline passes, the remaining turns are
/// cancelled (they end as "interrupted", exactly like a crash would leave
/// them). Once idle, the coordinator snapshots which sessions had a live
/// agent process (or a held prompt) and closes those processes cleanly; the
/// next boot reads the snapshot and brings those sessions back before
/// draining their held prompts (`restart-resume.ts`).
///
/// `cancel` abandons a drain whose update never happened (the download
/// failed, the host app aborted): the gate reopens and every held session
/// re-drains, so an aborted update never leaves chats stuck waiting.

export const DEFAULT_RESTART_DRAIN_TIMEOUT_MS = 10 * 60_000
/// How long a drained server may sit without actually restarting before the
/// drain is abandoned. Guards against an updater that accepted the handoff
/// and then silently gave up, which would otherwise hold prompts forever.
export const DRAINED_WITHOUT_RESTART_GRACE_MS = 15 * 60_000
/// After cancelling the remaining turns, how long to wait for their terminal
/// events before restarting regardless.
const INTERRUPT_SETTLE_MS = 15_000
const POLL_MS = 250

/// The transcript-facing identity of the restart gate. Held sessions show the
/// same "waiting for <name> update" marker a harness update gate shows.
export const RESTART_GATE_HARNESS_ID = "codevisor-server"
export const RESTART_GATE_HARNESS_NAME = "Codevisor"

export interface RestartSnapshotStore {
  readonly read: () => ReadonlyArray<string> | undefined
  readonly write: (sessionIds: ReadonlyArray<string>) => void
  readonly clear: () => void
}

/* v8 ignore start -- real filesystem persistence; the coordinator is covered
   through the in-memory store. */
export const makeFileRestartSnapshotStore = (path: string): RestartSnapshotStore => ({
  read: () => {
    try {
      if (!existsSync(path)) return undefined
      const parsed = JSON.parse(readFileSync(path, "utf8")) as { sessions?: unknown }
      return Array.isArray(parsed.sessions)
        ? parsed.sessions.filter((id): id is string => typeof id === "string")
        : undefined
    } catch {
      return undefined
    }
  },
  write: (sessionIds) => {
    mkdirSync(dirname(path), { recursive: true })
    const temporary = `${path}.${process.pid}.tmp`
    writeFileSync(
      temporary,
      `${JSON.stringify({ sessions: sessionIds, at: new Date().toISOString() })}\n`,
      { encoding: "utf8", mode: 0o600 }
    )
    renameSync(temporary, path)
  },
  clear: () => {
    rmSync(path, { force: true })
  }
})
/* v8 ignore stop */

export const makeMemoryRestartSnapshotStore = (): RestartSnapshotStore => {
  let value: ReadonlyArray<string> | undefined
  return {
    read: () => value,
    write: (sessionIds) => {
      value = [...sessionIds]
    },
    clear: () => {
      value = undefined
    }
  }
}

export interface RestartDrainOptions {
  /// Cancel the remaining live turns immediately instead of waiting.
  readonly interrupt?: boolean | undefined
  readonly timeoutMs?: number | undefined
}

export interface RestartCoordinator {
  readonly state: () => RestartDrainState
  /// True from `begin` until `cancel` (or the restart itself): prompt
  /// dispatch holds while this is set.
  readonly isGated: () => boolean
  /// Starts the drain (idempotent) and resolves once the server is idle and
  /// its sessions are snapshotted — i.e. safe to restart. A second call
  /// with `interrupt` cancels the remaining turns of a drain in progress.
  readonly begin: (options?: RestartDrainOptions) => Promise<RestartDrainState>
  /// Abandons the drain: reopens the gate, drops the snapshot, re-drains
  /// every held session. No-op when idle.
  readonly cancel: () => Promise<RestartDrainState>
  readonly close: () => void
}

export interface RestartCoordinatorDeps {
  readonly services: CodevisorServerServices
  readonly fanout: EventFanout
  readonly turns: {
    readonly activePromptSessions: Set<string>
    readonly activeTurnSessions: Set<string>
    readonly restartHeldSessions: Set<string>
  }
  readonly snapshot: RestartSnapshotStore
  readonly defaultTimeoutMs?: number | undefined
  readonly drainedGraceMs?: number | undefined
  readonly log?: ((line: string) => void) | undefined
  /// Re-drains a held session after `cancel` (the prompt queue drain in
  /// production; a recorder in the coordinator's own tests).
  readonly redrain: (sessionId: string) => Promise<void>
}

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms))

export const makeRestartCoordinator = (deps: RestartCoordinatorDeps): RestartCoordinator => {
  const { services, fanout, turns, snapshot, redrain } = deps
  const log = deps.log ?? ((line: string) => console.log(line))
  const defaultTimeoutMs = deps.defaultTimeoutMs ?? DEFAULT_RESTART_DRAIN_TIMEOUT_MS
  const drainedGraceMs = deps.drainedGraceMs ?? DRAINED_WITHOUT_RESTART_GRACE_MS

  let phase: RestartDrainState["state"] = "idle"
  /// When the current phase began.
  let startedAt = new Date().toISOString()
  let deadlineAt: number | undefined
  let interruptRequested = false
  let inFlight: Promise<RestartDrainState> | undefined
  let graceTimer: NodeJS.Timeout | undefined
  /// Bumped by `cancel` so a drain that was abandoned mid-wait never
  /// finalizes on top of the reopened gate.
  let generation = 0

  const liveSessions = (): Set<string> =>
    new Set([...turns.activePromptSessions, ...turns.activeTurnSessions])

  const state = (): RestartDrainState => ({
    state: phase,
    remaining: liveSessions().size,
    startedAt,
    ...(deadlineAt === undefined ? {} : { deadlineAt: new Date(deadlineAt).toISOString() })
  })

  const cancelLiveTurns = async (): Promise<void> => {
    for (const sessionId of liveSessions()) {
      try {
        const session = await run(services.db.getSessionSummary(sessionId))
        const agentSessionId =
          session.agentSessionId === undefined || session.agentSessionId === ""
            ? sessionId
            : session.agentSessionId
        await run(services.agents.cancel(agentSessionId))
      } catch (cause) {
        // A session whose process is already gone has nothing to cancel;
        // reconciliation closes its rows on the next boot.
        log(`Restart drain could not cancel ${sessionId}: ${failureMessage(cause)}`)
      }
    }
  }

  const waitUntilIdle = async (until: number, myGeneration: number): Promise<boolean> => {
    while (liveSessions().size > 0 && Date.now() < until) {
      await sleep(POLL_MS)
      if (generation !== myGeneration) return false
      if (interruptRequested) return true
    }
    return generation === myGeneration
  }

  /// Which sessions the next boot should bring back: every session with a
  /// live agent process, plus every session holding a prompt behind the
  /// gate (its process may already be closed, but its prompt is waiting).
  const sessionsToResume = async (): Promise<ReadonlyArray<string>> => {
    const loaded = new Set(services.agents.loadedAgentSessionIds())
    const ids = new Set<string>([...liveSessions(), ...turns.restartHeldSessions])
    if (loaded.size > 0) {
      const sessions = await run(services.db.listSessions)
      for (const session of sessions) {
        if (session.isArchived) continue
        const agentSessionId =
          session.agentSessionId === undefined || session.agentSessionId === ""
            ? session.id
            : session.agentSessionId
        if (loaded.has(agentSessionId)) ids.add(session.id)
      }
    }
    return [...ids].toSorted()
  }

  const finalize = async (): Promise<void> => {
    const resume = await sessionsToResume()
    snapshot.write(resume)
    for (const agentSessionId of services.agents.loadedAgentSessionIds()) {
      await run(services.agents.closeAgentSession(agentSessionId)).catch((cause: unknown) => {
        log(`Restart drain could not close ${agentSessionId}: ${failureMessage(cause)}`)
      })
    }
    log(
      `Restart drain complete: ${resume.length} session${resume.length === 1 ? "" : "s"} will resume after the restart`
    )
  }

  const drain = async (deadline: number, myGeneration: number): Promise<RestartDrainState> => {
    let idle = await waitUntilIdle(deadline, myGeneration)
    if (generation !== myGeneration) return state()
    if (liveSessions().size > 0 && idle) {
      // Deadline reached or interrupt requested: end the remaining turns
      // the way a client's Stop would, then give their terminal events a
      // moment to land so the transcript closes cleanly.
      log(`Restart drain interrupting ${liveSessions().size} live turn(s)`)
      await cancelLiveTurns()
      interruptRequested = false
      idle = await waitUntilIdle(Date.now() + INTERRUPT_SETTLE_MS, myGeneration)
      if (generation !== myGeneration) return state()
    }
    await finalize()
    if (generation !== myGeneration) return state()
    phase = "drained"
    deadlineAt = undefined
    graceTimer = setTimeout(() => {
      log("Restart drain abandoned: the server never restarted")
      void coordinator.cancel()
    }, drainedGraceMs)
    graceTimer.unref()
    return state()
  }

  const coordinator: RestartCoordinator = {
    state,
    isGated: () => phase !== "idle",
    begin: (options) => {
      if (options?.interrupt === true) interruptRequested = true
      if (inFlight !== undefined) return inFlight
      if (phase === "drained") return Promise.resolve(state())
      phase = "draining"
      startedAt = new Date().toISOString()
      const deadline = Date.now() + (options?.timeoutMs ?? defaultTimeoutMs)
      deadlineAt = deadline
      const myGeneration = generation
      log(
        `Restart drain started: waiting for ${liveSessions().size} live turn(s) before restarting`
      )
      inFlight = drain(deadline, myGeneration).finally(() => {
        inFlight = undefined
      })
      return inFlight
    },
    cancel: async () => {
      if (phase === "idle") return state()
      generation += 1
      phase = "idle"
      startedAt = new Date().toISOString()
      deadlineAt = undefined
      interruptRequested = false
      if (graceTimer !== undefined) {
        clearTimeout(graceTimer)
        graceTimer = undefined
      }
      snapshot.clear()
      const held = [...turns.restartHeldSessions]
      turns.restartHeldSessions.clear()
      for (const sessionId of held) {
        await appendAndPublish(services.db, fanout, "session.updateGate.updated", sessionId, {
          harnessId: RESTART_GATE_HARNESS_ID,
          harnessName: RESTART_GATE_HARNESS_NAME,
          state: "released"
        }).catch(swallowError)
        void redrain(sessionId).catch(swallowError)
      }
      log("Restart drain cancelled: prompts dispatch again")
      return state()
    },
    close: () => {
      generation += 1
      if (graceTimer !== undefined) {
        clearTimeout(graceTimer)
        graceTimer = undefined
      }
    }
  }
  return coordinator
}
