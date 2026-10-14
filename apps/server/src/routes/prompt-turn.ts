import { recordTurnStartSnapshot } from "@codevisor/worktrees"

import {
  run,
  swallowError,
  type CodevisorServerServices,
  type RouteState
} from "../server-context.js"

export interface PromptTurn {
  readonly harnessId: string | undefined
  readonly release: () => void
  readonly isReleased: () => boolean
}

export const beginPromptTurn = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  sessionId: string
): Promise<PromptTurn> => {
  routeState.activePromptSessions.add(sessionId)
  let harnessId: string | undefined
  let released = false
  const release = (): void => {
    if (released) return
    released = true
    routeState.promptTurnReleases.delete(sessionId)
    routeState.activePromptSessions.delete(sessionId)
    /* v8 ignore next */
    if (harnessId !== undefined) services.lifecycle?.notifyTurnEnded(harnessId)
  }
  routeState.promptTurnReleases.set(sessionId, release)
  const summary = await run(services.db.getSessionSummary(sessionId)).catch(swallowError)
  if (!released && summary !== undefined) {
    harnessId = summary.harnessId
    services.lifecycle?.notifyTurnStarted(harnessId)
  }
  return { harnessId, isReleased: () => released, release }
}

const turnStartSnapshotBudgetMs = 2_000

export const recordTurnStart = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<void> => {
  const { cwd } = await run(services.db.getSessionSummary(sessionId))
  /* v8 ignore next */
  if (cwd === undefined) return
  const env = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
  const signal = AbortSignal.timeout(turnStartSnapshotBudgetMs)
  const expired = new Promise((resolve) => {
    signal.addEventListener("abort", resolve, { once: true })
  })
  await Promise.race([recordTurnStartSnapshot(cwd, { env, signal }), expired])
}
