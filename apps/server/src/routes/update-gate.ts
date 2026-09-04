import type { SessionUpdateGate } from "@codevisor/api"
import { RESTART_GATE_HARNESS_ID, RESTART_GATE_HARNESS_NAME } from "../restart-drain.js"
import type { CodevisorServerServices, RouteState } from "../server-context.js"

/// The gate currently holding a session's prompts, if any: the restart drain
/// (an update waiting for live turns) or the session's harness mid-update.
/// Read from the same in-memory state that drives the `session.updateGate
/// .updated` events, so a snapshot and the stream can never disagree.
export const currentUpdateGate = (
  services: CodevisorServerServices,
  routeState: RouteState,
  sessionId: string
): SessionUpdateGate | undefined => {
  if (routeState.restartHeldSessions.has(sessionId)) {
    return { harnessId: RESTART_GATE_HARNESS_ID, harnessName: RESTART_GATE_HARNESS_NAME }
  }
  const harnessId = routeState.gatedSessions.get(sessionId)
  if (harnessId === undefined) return undefined
  const catalogName = services.agents.catalog.find(
    (definition) => definition.id === harnessId
  )?.name
  /* v8 ignore next -- defensive: sessions on uncataloged harnesses fall back to the id. */
  return { harnessId, harnessName: catalogName ?? harnessId }
}

/// Stamps a session snapshot (detail or transcript page) with its live gate.
/// Snapshots are what a reconnecting client trusts; without this, a marker
/// set by a `waiting` event whose `released` twin the client never saw (the
/// server restarted in between) would stick until the app relaunched.
export const withUpdateGate = <T extends object>(
  snapshot: T,
  services: CodevisorServerServices,
  routeState: RouteState,
  sessionId: string
): T & { readonly updateGate?: SessionUpdateGate } => {
  const updateGate = currentUpdateGate(services, routeState, sessionId)
  return updateGate === undefined ? snapshot : { ...snapshot, updateGate }
}
