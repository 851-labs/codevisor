import type { PausedTurn, PausedTurnStore } from "./paused-turns.js"
import { noteBotPrompt } from "./routes/bot-turns.js"
import { drainPromptQueue, hasLiveTurn } from "./routes/prompt-queue.js"
import {
  failureMessage,
  run,
  sessionIsArchived,
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "./server-context.js"
import { forgetUpdatePause } from "./update-pauses.js"

export const UPDATE_RESUME_STAGGER_MS = 3_000
export const UPDATE_CONTINUE_PROMPT = "continue"

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
  { sessionId, awaitsBotReply }: PausedTurn
): Promise<void> => {
  forgetUpdatePause(services, sessionId)
  if (!(await canContinue(services, routeState, sessionId))) return

  if (awaitsBotReply === true) noteBotPrompt(services, sessionId, "user")
  await queueContinueFirst(services, sessionId)
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

const queueContinueFirst = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<void> => {
  const item = await run(
    services.db.createPromptQueueItem(
      sessionId,
      UPDATE_CONTINUE_PROMPT,
      [],
      undefined,
      undefined,
      "system"
    )
  )
  await run(services.db.reorderPromptQueue(sessionId, [item.id]))
}
