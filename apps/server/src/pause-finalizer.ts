import { scopeIncludes, type PauseScope } from "./pause-scope.js"
import type { PausedTurn, PausedTurnStore } from "./paused-turns.js"
import { sessionTaskDescriptions } from "./restart-notice.js"
import type { RestartSnapshotStore } from "./restart-snapshot.js"
import {
  appendAndPublish,
  failureMessage,
  run,
  swallowError,
  type CodevisorServerServices,
  type EventFanout
} from "./server-context.js"

export interface PauseFinalizer {
  readonly finalize: (scope: PauseScope, isCurrent: () => boolean) => Promise<void>
}

export interface PauseFinalizerDeps {
  readonly services: CodevisorServerServices
  readonly fanout: EventFanout
  readonly snapshot: RestartSnapshotStore
  readonly pausedTurns: PausedTurnStore
  readonly heldSessionIds: () => ReadonlyArray<string>
  readonly destructive: (work: Promise<unknown>) => Promise<void>
  readonly log: (line: string) => void
}

interface StoppedTasks {
  readonly sessionId: string
  readonly tasks: ReadonlyArray<string>
}

export const makePauseFinalizer = (deps: PauseFinalizerDeps): PauseFinalizer => {
  const { services, snapshot, pausedTurns, destructive, log } = deps

  const closeSessions = async (
    agentSessionIds: ReadonlyArray<string>,
    isCurrent: () => boolean
  ): Promise<void> => {
    for (const agentSessionId of agentSessionIds) {
      if (!isCurrent()) return
      await destructive(run(services.agents.closeAgentSession(agentSessionId))).catch(
        (cause: unknown) => {
          log(`Restart drain could not close ${agentSessionId}: ${failureMessage(cause)}`)
        }
      )
    }
  }

  const withHeldSessions = (required: ReadonlyArray<string>): ReadonlyArray<string> =>
    [...new Set([...required, ...deps.heldSessionIds()])].toSorted()

  const runningTasks = async (
    sessionIds: ReadonlyArray<string>
  ): Promise<ReadonlyArray<StoppedTasks>> => {
    const found = await Promise.all(
      sessionIds.map(async (sessionId) => ({
        sessionId,
        tasks: await sessionTaskDescriptions(services, sessionId)
      }))
    )
    return found.filter((entry) => entry.tasks.length > 0)
  }

  const markStopped = async ({ sessionId, tasks }: StoppedTasks): Promise<void> => {
    const paused = pausedTurns.read().find((turn) => turn.sessionId === sessionId)
    pausedTurns.add([{ ...(paused ?? idleTurn(sessionId)), stoppedTasks: tasks }])
    await appendAndPublish(services.db, deps.fanout, "session.updated", sessionId, {
      backgroundTasks: []
    }).catch(swallowError)
  }

  const markAllStopped = async (stopped: ReadonlyArray<StoppedTasks>): Promise<void> => {
    for (const entry of stopped) await markStopped(entry)
  }

  const beforeRestart = async (isCurrent: () => boolean): Promise<void> => {
    const required = await run(services.db.listSessionsRequiringResume)
    const stopping = await runningTasks(required)
    if (!isCurrent()) return

    const resume = withHeldSessions(required)
    snapshot.write(resume)
    await closeSessions(services.agents.loadedAgentSessionIds(), isCurrent)
    if (isCurrent()) await markAllStopped(stopping)
    log(
      `Restart drain complete: ${resume.length} session${resume.length === 1 ? "" : "s"} will resume after the restart`
    )
  }

  const beforeHarnessUpdate = async (
    scope: PauseScope,
    isCurrent: () => boolean
  ): Promise<void> => {
    const loaded = services.agents.loadedAgentSessions()
    const restartable = loaded.filter(
      (session) => session.resumable && scopeIncludes(scope, session.harnessId)
    )
    const kept = loaded.filter(
      (session) => !session.resumable && scopeIncludes(scope, session.harnessId)
    )
    await closeSessions(
      restartable.map((session) => session.sessionId),
      isCurrent
    )
    log(
      `Paused chats for the harness update: closed ${restartable.length}, kept ${kept.length} that can't resume`
    )
  }

  return {
    finalize: (scope, isCurrent) => {
      if (scope.kind === "all") return beforeRestart(isCurrent)
      return beforeHarnessUpdate(scope, isCurrent)
    }
  }
}

const idleTurn = (sessionId: string): PausedTurn => ({
  sessionId,
  pausedAt: new Date().toISOString()
})
