import type { AgentState, SessionSummary, TranscriptPage } from "@codevisor/api"

import type { RouteState } from "../server-context.js"

export const agentState = (
  session: SessionSummary,
  page: Pick<TranscriptPage, "pendingQuestion">,
  turnEndHeld: boolean
): AgentState => {
  if (session.sidebarState === "errored") return "errored"
  if (page.pendingQuestion !== undefined || session.actionRequired === true) return "waitingForUser"
  if (session.sidebarState === "inProgress" || turnEndHeld) return "working"
  return "idle"
}

export const turnEndIsHeld = (
  routeState: Pick<RouteState, "heldTurnEnds">,
  session: Pick<SessionSummary, "id">
): boolean => routeState.heldTurnEnds.has(session.id)
