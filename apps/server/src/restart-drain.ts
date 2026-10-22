import type { RestartDrainState, SessionUpdateGate } from "@codevisor/api"

import { makePauseFinalizer } from "./pause-finalizer.js"
import { allChats, sameScope, scopeIncludes, widenScope, type PauseScope } from "./pause-scope.js"
import type { PausedTurn, PausedTurnStore } from "./paused-turns.js"
import type { RestartSnapshotStore } from "./restart-snapshot.js"
import { awaitsBotReply, conversationalBotForSession } from "./routes/bot-turns.js"
import {
  appendAndPublish,
  failureMessage,
  run,
  swallowError,
  type CodevisorServerServices,
  type EventFanout
} from "./server-context.js"
import { forgetUpdatePauses, markPausingForUpdate } from "./update-pauses.js"

export const DRAINED_WITHOUT_RESTART_GRACE_MS = 15 * 60_000
export const PAUSE_SETTLE_MS = 15_000
const POLL_MS = 250

export const RESTART_GATE_HARNESS_ID = "codevisor-server"
export const RESTART_GATE_HARNESS_NAME = "Codevisor"

interface PauseTarget {
  readonly agentSessionId: string
  readonly turn: PausedTurn
}

export interface RestartCoordinator {
  readonly state: () => RestartDrainState
  readonly isActive: () => boolean
  readonly gates: (harnessId: string | undefined) => boolean
  readonly gateFor: (harnessId: string | undefined) => SessionUpdateGate
  readonly begin: (scope?: PauseScope) => Promise<RestartDrainState>
  readonly cancel: () => Promise<RestartDrainState>
  readonly extendGrace: () => void
  readonly close: () => void
}

export interface RestartCoordinatorDeps {
  readonly services: CodevisorServerServices
  readonly fanout: EventFanout
  readonly turns: {
    readonly activePromptSessions: Set<string>
    readonly activeTurnSessions: Set<string>
    readonly restartHeldSessions: Map<string, SessionUpdateGate>
  }
  readonly snapshot: RestartSnapshotStore
  readonly pausedTurns: PausedTurnStore
  readonly log?: ((line: string) => void) | undefined
  readonly redrain: (sessionId: string) => Promise<void>
  readonly resumePaused: () => void
  readonly onChange?: (() => void) | undefined
}

export const makeRestartCoordinator = (deps: RestartCoordinatorDeps): RestartCoordinator => {
  const { services, fanout, turns, pausedTurns, redrain } = deps
  const log = deps.log ?? ((line: string) => console.log(line))

  let phase: RestartDrainState["state"] = "idle"
  let scope: PauseScope = allChats
  let liveInScope = 0
  let startedAt = new Date().toISOString()
  let inFlight: Promise<RestartDrainState> | undefined
  let cancelling: Promise<RestartDrainState> | undefined
  let destructiveWork: Promise<unknown> | undefined
  let graceTimer: NodeJS.Timeout | undefined
  let generation = 0

  const liveSessions = (): Set<string> =>
    new Set([...turns.activePromptSessions, ...turns.activeTurnSessions])

  const harnessName = (harnessId: string): string =>
    services.agents.catalog.find((candidate) => candidate.id === harnessId)?.name ?? harnessId

  const harnessScope = (harnessIds: ReadonlyArray<string>) => ({
    harnessIds,
    harnessNames: Object.fromEntries(harnessIds.map((id) => [id, harnessName(id)]))
  })

  const state = (): RestartDrainState => ({
    state: phase,
    remaining: scope.kind === "all" ? liveSessions().size : liveInScope,
    startedAt,
    pausedSessionIds: pausedTurns.read().map((turn) => turn.sessionId),
    ...(phase !== "idle" && scope.kind === "harnesses" ? harnessScope(scope.harnessIds) : {})
  })

  const changed = (): void => {
    deps.onChange?.()
  }

  const gates = (harnessId: string | undefined): boolean =>
    phase !== "idle" && scopeIncludes(scope, harnessId)

  const gateFor = (harnessId: string | undefined): SessionUpdateGate => {
    if (scope.kind === "all" || harnessId === undefined) {
      return { harnessId: RESTART_GATE_HARNESS_ID, harnessName: RESTART_GATE_HARNESS_NAME }
    }

    return { harnessId, harnessName: harnessName(harnessId) }
  }

  const destructive = async (work: Promise<unknown>): Promise<void> => {
    destructiveWork = work
    try {
      await work
    } finally {
      destructiveWork = undefined
    }
  }

  const harnessOf = async (sessionId: string): Promise<string | undefined> => {
    const session = await run(services.db.getSessionSummary(sessionId)).catch(swallowError)
    return session?.harnessId
  }

  const liveSessionsIn = async (pauseScope: PauseScope): Promise<ReadonlyArray<string>> => {
    const live = [...liveSessions()]
    if (pauseScope.kind === "all") return live

    const harnesses = await Promise.all(live.map(harnessOf))
    return live.filter((_, index) => scopeIncludes(pauseScope, harnesses[index]))
  }

  const countLive = async (pauseScope: PauseScope): Promise<number> => {
    const count = (await liveSessionsIn(pauseScope)).length
    if (count !== liveInScope) {
      liveInScope = count
      changed()
    }
    return count
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
    markPausingForUpdate(services, turn.sessionId)
    await run(services.agents.cancel(agentSessionId)).catch((cause: unknown) => {
      log(`Restart drain could not interrupt ${turn.sessionId}: ${failureMessage(cause)}`)
    })
  }

  const pauseLiveTurns = async (myGeneration: number, pauseScope: PauseScope): Promise<void> => {
    const sessionIds = await liveSessionsIn(pauseScope)
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

  const waitUntilIdle = async (
    until: number,
    myGeneration: number,
    pauseScope: PauseScope
  ): Promise<void> => {
    while ((await countLive(pauseScope)) > 0 && Date.now() < until) {
      await pollPause()
      if (generation !== myGeneration) return
    }
  }

  const finalizer = makePauseFinalizer({
    services,
    snapshot: deps.snapshot,
    heldSessionIds: () => [...turns.restartHeldSessions.keys()],
    destructive,
    log
  })

  const armGrace = (): void => {
    if (graceTimer !== undefined) clearTimeout(graceTimer)
    graceTimer = setTimeout(() => {
      log("Restart drain abandoned: the server never restarted")
      void coordinator.cancel()
    }, DRAINED_WITHOUT_RESTART_GRACE_MS)
    graceTimer.unref()
  }

  const drain = async (
    myGeneration: number,
    pauseScope: PauseScope
  ): Promise<RestartDrainState> => {
    await pauseLiveTurns(myGeneration, pauseScope)
    if (generation !== myGeneration) return state()

    await waitUntilIdle(Date.now() + PAUSE_SETTLE_MS, myGeneration, pauseScope)
    if (generation !== myGeneration) return state()

    let finalized = true
    try {
      await finalizer.finalize(pauseScope, () => generation === myGeneration)
    } catch (cause) {
      log(`Restart drain could not finish: ${failureMessage(cause)}`)
      finalized = false
    }
    if (generation !== myGeneration) return state()
    if (!finalized) return coordinator.cancel()
    if (!sameScope(scope, pauseScope)) return state()

    phase = "drained"
    changed()
    if (pauseScope.kind === "all") armGrace()
    return state()
  }

  const startDrain = (requested: PauseScope): Promise<RestartDrainState> => {
    if (phase === "idle") startedAt = new Date().toISOString()
    scope = requested
    phase = "draining"
    changed()
    const myGeneration = generation
    const previous = inFlight ?? Promise.resolve(state())
    log(`Restart drain started: pausing ${liveSessions().size} live turn(s) before restarting`)
    const work = previous
      .then(() => (generation === myGeneration ? drain(myGeneration, requested) : state()))
      .finally(() => {
        if (inFlight === work) inFlight = undefined
      })
    inFlight = work
    return followLatest(work)
  }

  const followLatest = async (work: Promise<RestartDrainState>): Promise<RestartDrainState> => {
    const settled = await work
    if (inFlight === undefined || inFlight === work) return settled
    return followLatest(inFlight)
  }

  const releaseHeld = async (): Promise<void> => {
    const held = [...turns.restartHeldSessions]
    turns.restartHeldSessions.clear()
    for (const [sessionId, gate] of held) {
      await appendAndPublish(services.db, fanout, "session.updateGate.updated", sessionId, {
        ...gate,
        state: "released"
      }).catch(swallowError)
      void redrain(sessionId).catch(swallowError)
    }
  }

  const coordinator: RestartCoordinator = {
    state,
    isActive: () => phase !== "idle",
    gates,
    gateFor,
    begin: (requested = allChats) => {
      if (cancelling !== undefined) return cancelling.then(() => coordinator.begin(requested))
      if (phase === "idle") return startDrain(requested)

      const widened = widenScope(scope, requested)
      if (!sameScope(widened, scope)) return startDrain(widened)
      if (inFlight === undefined) return Promise.resolve(state())
      return followLatest(inFlight)
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
        scope = allChats
        liveInScope = 0
        startedAt = new Date().toISOString()
        changed()
        forgetUpdatePauses(services)
        if (graceTimer !== undefined) {
          clearTimeout(graceTimer)
          graceTimer = undefined
        }
        try {
          deps.snapshot.clear()
        } catch (cause) {
          log(`Restart drain could not clear its snapshot: ${failureMessage(cause)}`)
        }
        deps.resumePaused()
        await releaseHeld()
        log("Restart drain cancelled: prompts dispatch again")
        return state()
      })().finally(() => {
        cancelling = undefined
      })
      cancelling = cancel
      return cancel
    },
    extendGrace: () => {
      if (graceTimer !== undefined) armGrace()
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

const owesBotReply = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<boolean> =>
  awaitsBotReply(services, sessionId) &&
  (await conversationalBotForSession(services, sessionId)) !== undefined

const pausedTurnOf = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<PausedTurn> => {
  const pausedAt = new Date().toISOString()
  const latest = (await run(services.db.getTranscriptPage(sessionId, undefined, 1))).items.at(-1)
  const turnId = latest?.isGenerating === true ? latest.turnId : undefined
  return {
    sessionId,
    ...(turnId === undefined ? {} : { turnId }),
    pausedAt,
    ...((await owesBotReply(services, sessionId)) ? { awaitsBotReply: true } : {})
  }
}
