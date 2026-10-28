import type { AgentState, SessionSummary, TranscriptPage } from "@codevisor/api"

export const agentState = (
  session: SessionSummary,
  page: Pick<TranscriptPage, "pendingQuestion">
): AgentState => {
  if (session.sidebarState === "errored") return "errored"
  if (page.pendingQuestion !== undefined || session.actionRequired === true) return "waitingForUser"
  if (session.sidebarState === "inProgress") return "working"
  return "idle"
}
