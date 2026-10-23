import type { AgentState, SessionSummary, TranscriptPage } from "@codevisor/api"

export const agentState = (
  session: SessionSummary,
  page: Pick<TranscriptPage, "pendingQuestion" | "backgroundTasks">
): AgentState => {
  if (session.sidebarState === "errored") return "errored"
  if (page.pendingQuestion !== undefined || session.actionRequired === true) return "waitingForUser"
  if (session.sidebarState === "inProgress" || hasLiveBackgroundTasks(page)) return "working"
  return "idle"
}

const hasLiveBackgroundTasks = (page: Pick<TranscriptPage, "backgroundTasks">): boolean =>
  (page.backgroundTasks ?? []).length > 0
