import { scopeIncludes, type PauseScope } from "./pause-scope.js"
import type { RestartSnapshotStore } from "./restart-snapshot.js"
import { failureMessage, run, type CodevisorServerServices } from "./server-context.js"

export interface PauseFinalizer {
  readonly finalize: (scope: PauseScope, isCurrent: () => boolean) => Promise<void>
}

export interface PauseFinalizerDeps {
  readonly services: CodevisorServerServices
  readonly snapshot: RestartSnapshotStore
  readonly heldSessionIds: () => ReadonlyArray<string>
  readonly destructive: (work: Promise<unknown>) => Promise<void>
  readonly log: (line: string) => void
}

export const makePauseFinalizer = (deps: PauseFinalizerDeps): PauseFinalizer => {
  const { services, snapshot, destructive, log } = deps

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

  const sessionsToResume = async (): Promise<ReadonlyArray<string>> => {
    const ids = new Set<string>([
      ...(await run(services.db.listSessionsRequiringResume)),
      ...deps.heldSessionIds()
    ])
    return [...ids].toSorted()
  }

  const beforeRestart = async (isCurrent: () => boolean): Promise<void> => {
    const resume = await sessionsToResume()
    if (!isCurrent()) return

    snapshot.write(resume)
    await closeSessions(services.agents.loadedAgentSessionIds(), isCurrent)
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
