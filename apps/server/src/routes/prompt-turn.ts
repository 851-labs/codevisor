import { recordTurnStartSnapshot } from "@codevisor/worktrees"

import {
  run,
  swallowError,
  type CodevisorServerServices,
  type RouteState
} from "../server-context.js"

/// One prompt drain's claim on its session's turn: listed in
/// `activePromptSessions` and counted against its harness, so the restart
/// drain and a harness update armed for "when idle" both wait for it.
export interface PromptTurn {
  readonly harnessId: string | undefined
  /// Ends the claim. Idempotent: called when the drain exits, and earlier
  /// when the chat's runtime is retired (see `promptTurnReleases`).
  readonly release: () => void
  readonly isReleased: () => boolean
}

/// Claims the session's turn for a prompt drain. The claim is registered in
/// `promptTurnReleases` because a retired runtime's prompt may never settle —
/// a turn blocked on a question, or a harness that ignores close — and the
/// drain holding it would otherwise keep harness and server updates waiting
/// on a chat nobody can see.
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
    // A replacement starts only after retirement has invoked this release.
    // The idempotence guard above keeps a retired drain from releasing it.
    routeState.promptTurnReleases.delete(sessionId)
    routeState.activePromptSessions.delete(sessionId)
    /* v8 ignore next -- defensive: unknown sessions simply skip turn accounting. */
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

/// How long a prompt waits for its turn-start snapshot. Capturing a large
/// checkout can take a while; past this the turn starts anyway and the Review
/// pane's "last turn" keeps comparing against the previous snapshot.
const turnStartSnapshotBudgetMs = 2_000

/// Records the session folder's working tree so the Review pane can show what
/// this turn changed. Bounded because the user is waiting on the prompt, and
/// the snapshot is abandoned — not written late — once the agent may already
/// be editing files it would capture. Runs before the agent session is
/// started or resumed, so the archive check there still guards the prompt.
export const recordTurnStart = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<void> => {
  const { cwd } = await run(services.db.getSessionSummary(sessionId))
  /* v8 ignore next -- server-created local sessions always retain their project working directory. */
  if (cwd === undefined) return
  const env = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
  const signal = AbortSignal.timeout(turnStartSnapshotBudgetMs)
  const expired = new Promise((resolve) => {
    signal.addEventListener("abort", resolve, { once: true })
  })
  await Promise.race([recordTurnStartSnapshot(cwd, { env, signal }), expired])
}
