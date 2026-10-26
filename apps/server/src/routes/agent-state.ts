import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import type { AgentState, SessionSummary, TranscriptPage } from "@codevisor/api"

export const agentState = (
  session: SessionSummary,
  page: Pick<TranscriptPage, "pendingQuestion" | "backgroundTasks">,
  harnessLoaded: boolean
): AgentState => {
  if (session.sidebarState === "errored") return "errored"
  if (page.pendingQuestion !== undefined || session.actionRequired === true) return "waitingForUser"
  if (session.sidebarState === "inProgress" || hasLiveBackgroundTasks(page, harnessLoaded))
    return "working"
  return "idle"
}

export const harnessIsLoaded = (
  agents: Pick<AgentRuntimeService, "loadedAgentSessionIds">,
  session: Pick<SessionSummary, "agentSessionId">
): boolean =>
  session.agentSessionId !== undefined &&
  agents.loadedAgentSessionIds().includes(session.agentSessionId)

const hasLiveBackgroundTasks = (
  page: Pick<TranscriptPage, "backgroundTasks">,
  harnessLoaded: boolean
): boolean => harnessLoaded && (page.backgroundTasks ?? []).length > 0
