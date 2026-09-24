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
  const harnessId = await run(services.db.getSessionSummary(sessionId))
    .then((session) => session.harnessId)
    .catch(swallowError)
  /* v8 ignore next -- defensive: unknown sessions simply skip turn accounting. */
  if (harnessId !== undefined) services.lifecycle?.notifyTurnStarted(harnessId)
  let released = false
  const release = (): void => {
    if (released) return
    released = true
    // Unconditional: no newer drain can have registered for this session
    // while this claim held it in `activePromptSessions`.
    routeState.promptTurnReleases.delete(sessionId)
    routeState.activePromptSessions.delete(sessionId)
    /* v8 ignore next -- defensive: unknown sessions simply skip turn accounting. */
    if (harnessId !== undefined) services.lifecycle?.notifyTurnEnded(harnessId)
  }
  routeState.promptTurnReleases.set(sessionId, release)
  return { harnessId, isReleased: () => released, release }
}
