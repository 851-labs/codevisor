import type { SessionUpdateGate } from "@codevisor/api"

import { RESTART_GATE_HARNESS_ID, RESTART_GATE_HARNESS_NAME } from "../restart-drain.js"
import type { CodevisorServerServices, RouteState } from "../server-context.js"

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
  /* v8 ignore next */
  return { harnessId, harnessName: catalogName ?? harnessId }
}

export const withUpdateGate = <T extends object>(
  snapshot: T,
  services: CodevisorServerServices,
  routeState: RouteState,
  sessionId: string
): T & { readonly updateGate?: SessionUpdateGate } => {
  const updateGate = currentUpdateGate(services, routeState, sessionId)
  return updateGate === undefined ? snapshot : { ...snapshot, updateGate }
}
