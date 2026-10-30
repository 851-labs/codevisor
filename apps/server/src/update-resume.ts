import type { EventEnvelope } from "@codevisor/api"

import type { PausedTurn, PausedTurnStore } from "./paused-turns.js"
import { queueRestartResumeOnce, updateResumeNotice } from "./restart-notice.js"
import { pendingAgentQuestion } from "./routes/parked-questions.js"
import { drainPromptQueue, hasLiveTurn } from "./routes/prompt-queue.js"
import { ensureAgentSessionFor } from "./routes/session-workspace.js"
import {
  failureMessage,
  run,
  sessionIsArchived,
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "./server-context.js"
import { isRecord } from "./unknown-values.js"
import { forgetUpdatePause } from "./update-pauses.js"

export const UPDATE_RESUME_STAGGER_MS = 3_000
export const NATIVE_RESUME_START_MS = 20_000

export interface UpdateResumer {
  readonly resume: (turns: ReadonlyArray<PausedTurn>) => void
  readonly isPending: (sessionId: string) => boolean
  readonly cancel: (sessionId: string) => void
  readonly close: () => void
}

export interface UpdateResumerDeps {
  readonly pausedTurns: PausedTurnStore
  readonly continueSession: (turn: PausedTurn) => Promise<void>
  readonly staggerMs?: number | undefined
  readonly log?: ((line: string) => void) | undefined
}

export const makeUpdateResumer = (deps: UpdateResumerDeps): UpdateResumer => {
  const { pausedTurns, continueSession } = deps
  const staggerMs = deps.staggerMs ?? UPDATE_RESUME_STAGGER_MS
  const log = deps.log ?? ((line: string) => console.log(line))
  const timers = new Map<string, NodeJS.Timeout>()

  const fire = async (turn: PausedTurn): Promise<void> => {
    timers.delete(turn.sessionId)
    try {
      await continueSession(turn)
    } catch (cause) {
      log(`Could not continue ${turn.sessionId} after the update: ${failureMessage(cause)}`)
    }
    pausedTurns.remove(turn.sessionId)
  }

  const schedule = (turn: PausedTurn, slot: number): void => {
    const timer = setTimeout(() => void fire(turn), slot * staggerMs)
    timer.unref()
    timers.set(turn.sessionId, timer)
  }

  return {
    resume: (turns) => {
      const waiting = turns.filter((turn) => !timers.has(turn.sessionId))
      if (waiting.length > 0) log(`Continuing ${waiting.length} chat(s) paused for the update`)
      waiting.forEach(schedule)
    },
    isPending: (sessionId) => timers.has(sessionId),
    cancel: (sessionId) => {
      clearTimeout(timers.get(sessionId))
      timers.delete(sessionId)
      pausedTurns.remove(sessionId)
    },
    close: () => {
      for (const timer of timers.values()) clearTimeout(timer)
      timers.clear()
    }
  }
}

export const continueAfterUpdate = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  turn: PausedTurn
): Promise<void> => {
  const { sessionId } = turn
  forgetUpdatePause(services, sessionId)
  if (!(await canContinue(services, routeState, sessionId))) return
  if (await waitsForAnswer(services, turn)) return
  if (await resumedNatively(services, fanout, serverId, turn)) {
    void drainPromptQueue(services, fanout, routeState, serverId, sessionId).catch(swallowError)
    return
  }

  await queueResumeFirst(services, turn)
  void drainPromptQueue(services, fanout, routeState, serverId, sessionId).catch(swallowError)
}

const canContinue = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  sessionId: string
): Promise<boolean> => {
  if (hasLiveTurn(routeState, sessionId)) return false
  const session = await run(services.db.getSessionSummary(sessionId))
  return !(await sessionIsArchived(services, session))
}

const waitsForAnswer = async (
  services: CodevisorServerServices,
  { sessionId, stoppedTasks = [] }: PausedTurn
): Promise<boolean> =>
  stoppedTasks.length === 0 && (await pendingAgentQuestion(services, sessionId)) !== undefined

const resumedNatively = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  { sessionId, stoppedTasks = [], resumesInterruptedTurn }: PausedTurn
): Promise<boolean> => {
  if (resumesInterruptedTurn !== true || (await agentSessionLoaded(services, sessionId))) {
    return false
  }

  const started = watchTurnStart(fanout, sessionId)
  try {
    await ensureAgentSessionFor(services, fanout, serverId, sessionId, {
      resumeInterruptedTurn: { notice: updateResumeNotice(stoppedTasks), stoppedTasks }
    })
    return await started.within(NATIVE_RESUME_START_MS)
  } catch {
    return false
  } finally {
    started.stop()
  }
}

const agentSessionLoaded = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<boolean> => {
  const { agentSessionId } = await run(services.db.getSessionSummary(sessionId))
  return services.agents.loadedAgentSessionIds().includes(agentSessionId ?? sessionId)
}

const watchTurnStart = (fanout: EventFanout, sessionId: string) => {
  let started = false
  let wake: (() => void) | undefined
  const stop = fanout.subscribe((event) => {
    if (!isTurnStart(event, sessionId)) return
    started = true
    wake?.()
  })
  const within = (ms: number): Promise<boolean> =>
    new Promise((resolve) => {
      if (started) return resolve(true)
      const timer = setTimeout(() => resolve(false), ms)
      wake = () => {
        clearTimeout(timer)
        resolve(true)
      }
    })
  return { stop, within }
}

const isTurnStart = (event: EventEnvelope, sessionId: string): boolean =>
  event.kind === "session.updated" &&
  event.subjectId === sessionId &&
  isRecord(event.payload) &&
  event.payload.turnState === "started"

const queueResumeFirst = async (
  services: CodevisorServerServices,
  { sessionId, stoppedTasks = [] }: PausedTurn
): Promise<void> => {
  await queueRestartResumeOnce(services, sessionId, updateResumeNotice(stoppedTasks))
}
