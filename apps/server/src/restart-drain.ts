import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"

import type { RestartDrainState } from "@codevisor/api"

import {
  appendAndPublish,
  failureMessage,
  run,
  swallowError,
  type CodevisorServerServices,
  type EventFanout
} from "./server-context.js"

export const DEFAULT_RESTART_DRAIN_TIMEOUT_MS = 10 * 60_000
export const DRAINED_WITHOUT_RESTART_GRACE_MS = 15 * 60_000
const INTERRUPT_SETTLE_MS = 15_000
const POLL_MS = 250

export const RESTART_GATE_HARNESS_ID = "codevisor-server"
export const RESTART_GATE_HARNESS_NAME = "Codevisor"

export interface RestartSnapshotStore {
  readonly read: () => ReadonlyArray<string> | undefined
  readonly write: (sessionIds: ReadonlyArray<string>) => void
  readonly clear: () => void
}

/* v8 ignore start */
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
  readonly interrupt?: boolean | undefined
  readonly timeoutMs?: number | undefined
}

export interface RestartCoordinator {
  readonly state: () => RestartDrainState
  readonly isGated: () => boolean
  readonly begin: (options?: RestartDrainOptions) => Promise<RestartDrainState>
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
  readonly log?: ((line: string) => void) | undefined
  readonly redrain: (sessionId: string) => Promise<void>
}

export const makeRestartCoordinator = (deps: RestartCoordinatorDeps): RestartCoordinator => {
  const { services, fanout, turns, snapshot, redrain } = deps
  const log = deps.log ?? ((line: string) => console.log(line))
  const defaultTimeoutMs = deps.defaultTimeoutMs ?? DEFAULT_RESTART_DRAIN_TIMEOUT_MS

  let phase: RestartDrainState["state"] = "idle"
  let startedAt = new Date().toISOString()
  let deadlineAt: number | undefined
  let interruptRequested = false
  let inFlight: Promise<RestartDrainState> | undefined
  let cancelling: Promise<RestartDrainState> | undefined
  let destructiveWork: Promise<unknown> | undefined
  let graceTimer: NodeJS.Timeout | undefined
  let generation = 0

  const liveSessions = (): Set<string> =>
    new Set([...turns.activePromptSessions, ...turns.activeTurnSessions])

  const state = (): RestartDrainState => ({
    state: phase,
    remaining: liveSessions().size,
    startedAt,
    ...(deadlineAt === undefined ? {} : { deadlineAt: new Date(deadlineAt).toISOString() })
  })

  const destructive = async (work: Promise<unknown>): Promise<void> => {
    destructiveWork = work
    try {
      await work
    } finally {
      destructiveWork = undefined
    }
  }

  const cancelLiveTurns = async (myGeneration: number): Promise<void> => {
    for (const sessionId of liveSessions()) {
      if (generation !== myGeneration) return
      try {
        const session = await run(services.db.getSessionSummary(sessionId))
        if (generation !== myGeneration) return
        const agentSessionId =
          session.agentSessionId === undefined || session.agentSessionId === ""
            ? sessionId
            : session.agentSessionId
        await destructive(run(services.agents.cancel(agentSessionId)))
      } catch (cause) {
        log(`Restart drain could not cancel ${sessionId}: ${failureMessage(cause)}`)
      }
    }
  }

  let wakeDrain: (() => void) | undefined
  const pollPause = (): Promise<void> =>
    new Promise((resolve) => {
      const done = (): void => {
        clearTimeout(timer)
        wakeDrain = undefined
        resolve()
      }
      const timer = setTimeout(done, POLL_MS)
      wakeDrain = done
    })

  const waitUntilIdle = async (until: number, myGeneration: number): Promise<boolean> => {
    while (liveSessions().size > 0 && Date.now() < until) {
      await pollPause()
      if (generation !== myGeneration) return false
      if (interruptRequested) return true
    }
    return generation === myGeneration
  }

  const sessionsToResume = async (): Promise<ReadonlyArray<string>> => {
    const ids = new Set<string>([
      ...(await run(services.db.listSessionsRequiringResume)),
      ...turns.restartHeldSessions
    ])
    return [...ids].toSorted()
  }

  const finalize = async (myGeneration: number): Promise<void> => {
    const resume = await sessionsToResume()
    if (generation !== myGeneration) return
    snapshot.write(resume)
    for (const agentSessionId of services.agents.loadedAgentSessionIds()) {
      if (generation !== myGeneration) return
      await destructive(run(services.agents.closeAgentSession(agentSessionId))).catch(
        (cause: unknown) => {
          log(`Restart drain could not close ${agentSessionId}: ${failureMessage(cause)}`)
        }
      )
    }
    log(
      `Restart drain complete: ${resume.length} session${resume.length === 1 ? "" : "s"} will resume after the restart`
    )
  }

  const drain = async (deadline: number, myGeneration: number): Promise<RestartDrainState> => {
    let idle = await waitUntilIdle(deadline, myGeneration)
    if (generation !== myGeneration) return state()
    if (liveSessions().size > 0 && idle) {
      log(`Restart drain interrupting ${liveSessions().size} live turn(s)`)
      await cancelLiveTurns(myGeneration)
      if (generation !== myGeneration) return state()
      interruptRequested = false
      idle = await waitUntilIdle(Date.now() + INTERRUPT_SETTLE_MS, myGeneration)
      if (generation !== myGeneration) return state()
    }
    let finalized = true
    try {
      await finalize(myGeneration)
    } catch (cause) {
      log(`Restart drain could not finish: ${failureMessage(cause)}`)
      finalized = false
    }
    if (generation !== myGeneration) return state()
    if (!finalized) {
      return coordinator.cancel()
    }
    phase = "drained"
    deadlineAt = undefined
    graceTimer = setTimeout(() => {
      log("Restart drain abandoned: the server never restarted")
      void coordinator.cancel()
    }, DRAINED_WITHOUT_RESTART_GRACE_MS)
    graceTimer.unref()
    return state()
  }

  const coordinator: RestartCoordinator = {
    state,
    isGated: () => phase !== "idle",
    begin: (options) => {
      if (cancelling !== undefined) return cancelling.then(() => coordinator.begin(options))
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
      const work = drain(deadline, myGeneration).finally(() => {
        if (inFlight === work) inFlight = undefined
      })
      inFlight = work
      return inFlight
    },
    cancel: () => {
      if (cancelling !== undefined) return cancelling
      if (phase === "idle") return Promise.resolve(state())
      generation += 1
      wakeDrain?.()
      inFlight = undefined
      const cancel = (async () => {
        if (destructiveWork !== undefined) await destructiveWork.catch(swallowError)
        phase = "idle"
        startedAt = new Date().toISOString()
        deadlineAt = undefined
        interruptRequested = false
        if (graceTimer !== undefined) {
          clearTimeout(graceTimer)
          graceTimer = undefined
        }
        try {
          snapshot.clear()
        } catch (cause) {
          log(`Restart drain could not clear its snapshot: ${failureMessage(cause)}`)
        }
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
      })().finally(() => {
        cancelling = undefined
      })
      cancelling = cancel
      return cancel
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
