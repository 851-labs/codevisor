import type { RestartDrainState } from "@codevisor/api"

import { readJsonStateFile, removeJsonStateFile, writeJsonStateFile } from "./json-state-file.js"
import type { PausedTurn, PausedTurnStore } from "./paused-turns.js"
import {
  appendAndPublish,
  failureMessage,
  run,
  swallowError,
  type CodevisorServerServices,
  type EventFanout
} from "./server-context.js"
import { forgetTurnInterruptions, markTurnInterrupted } from "./turn-interruptions.js"
import { field } from "./unknown-values.js"

export const DRAINED_WITHOUT_RESTART_GRACE_MS = 15 * 60_000
export const PAUSE_SETTLE_MS = 15_000
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
    const sessions = field(readJsonStateFile(path), "sessions")
    return Array.isArray(sessions)
      ? sessions.filter((id): id is string => typeof id === "string")
      : undefined
  },
  write: (sessionIds) => {
    writeJsonStateFile(path, { sessions: sessionIds, at: new Date().toISOString() })
  },
  clear: () => {
    removeJsonStateFile(path)
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

interface PauseTarget {
  readonly agentSessionId: string
  readonly turn: PausedTurn
}

export interface RestartCoordinator {
  readonly state: () => RestartDrainState
  readonly isGated: () => boolean
  readonly begin: () => Promise<RestartDrainState>
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
  readonly pausedTurns: PausedTurnStore
  readonly log?: ((line: string) => void) | undefined
  readonly redrain: (sessionId: string) => Promise<void>
  readonly resumePaused: () => void
}

export const makeRestartCoordinator = (deps: RestartCoordinatorDeps): RestartCoordinator => {
  const { services, fanout, turns, snapshot, pausedTurns, redrain } = deps
  const log = deps.log ?? ((line: string) => console.log(line))

  let phase: RestartDrainState["state"] = "idle"
  let startedAt = new Date().toISOString()
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
    startedAt
  })

  const destructive = async (work: Promise<unknown>): Promise<void> => {
    destructiveWork = work
    try {
      await work
    } finally {
      destructiveWork = undefined
    }
  }

  const pauseTarget = async (sessionId: string): Promise<PauseTarget | undefined> => {
    try {
      const session = await run(services.db.getSessionSummary(sessionId))
      return {
        agentSessionId: agentSessionIdOf(session),
        turn: await pausedTurnOf(services, sessionId)
      }
    } catch (cause) {
      log(`Restart drain could not pause ${sessionId}: ${failureMessage(cause)}`)
      return undefined
    }
  }

  const interruptTurn = async ({ agentSessionId, turn }: PauseTarget): Promise<void> => {
    markTurnInterrupted(services, turn.sessionId)
    await run(services.agents.cancel(agentSessionId)).catch((cause: unknown) => {
      log(`Restart drain could not interrupt ${turn.sessionId}: ${failureMessage(cause)}`)
    })
  }

  const pauseLiveTurns = async (myGeneration: number): Promise<void> => {
    const sessionIds = [...liveSessions()]
    if (sessionIds.length === 0) return

    const targets = (await Promise.all(sessionIds.map(pauseTarget))).filter(isDefined)
    if (generation !== myGeneration) return

    pausedTurns.add(targets.map((target) => target.turn))
    log(`Restart drain pausing ${targets.length} live turn(s)`)
    await destructive(Promise.all(targets.map(interruptTurn)))
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

  const waitUntilIdle = async (until: number, myGeneration: number): Promise<void> => {
    while (liveSessions().size > 0 && Date.now() < until) {
      await pollPause()
      if (generation !== myGeneration) return
    }
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

  const drain = async (myGeneration: number): Promise<RestartDrainState> => {
    await pauseLiveTurns(myGeneration)
    if (generation !== myGeneration) return state()

    await waitUntilIdle(Date.now() + PAUSE_SETTLE_MS, myGeneration)
    if (generation !== myGeneration) return state()

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
    begin: () => {
      if (cancelling !== undefined) return cancelling.then(() => coordinator.begin())
      if (inFlight !== undefined) return inFlight
      if (phase === "drained") return Promise.resolve(state())
      phase = "draining"
      startedAt = new Date().toISOString()
      const myGeneration = generation
      log(`Restart drain started: pausing ${liveSessions().size} live turn(s) before restarting`)
      const work = drain(myGeneration).finally(() => {
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
        forgetTurnInterruptions(services)
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
        deps.resumePaused()
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

const isDefined = <A>(value: A | undefined): value is A => value !== undefined

const agentSessionIdOf = (session: {
  readonly id: string
  readonly agentSessionId?: string | undefined
}): string =>
  session.agentSessionId === undefined || session.agentSessionId === ""
    ? session.id
    : session.agentSessionId

const pausedTurnOf = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<PausedTurn> => {
  const pausedAt = new Date().toISOString()
  const latest = (await run(services.db.getTranscriptPage(sessionId, undefined, 1))).items.at(-1)
  const turnId = latest?.isGenerating === true ? latest.turnId : undefined
  return turnId === undefined ? { sessionId, pausedAt } : { sessionId, turnId, pausedAt }
}
