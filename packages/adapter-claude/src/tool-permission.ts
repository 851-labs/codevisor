import type { CanUseTool, PermissionResult } from "@anthropic-ai/claude-agent-sdk"

import { holdClaudeApproval, holdClaudePlanApproval, holdClaudeQuestion } from "./questions.js"
import type { CurrentSession } from "./session.js"

type PermissionCheck = Parameters<CanUseTool>[2]

export const claudeToolPermission =
  (currentSession: CurrentSession): CanUseTool =>
  async (toolName, toolInput, check) => {
    const session = currentSession()
    if (session === undefined) return { behavior: "allow", updatedInput: toolInput }
    if (toolName === "AskUserQuestion") return holdClaudeQuestion(session, toolInput)
    if (toolName === "ExitPlanMode") return holdClaudePlanApproval(session, toolInput)
    if (session.currentModeId === "bypassPermissions") {
      return allowBypassEscalation(toolName, toolInput, check)
    }

    return holdClaudeApproval(session, toolName, toolInput)
  }

const allowBypassEscalation = (
  toolName: string,
  toolInput: Record<string, unknown>,
  check: PermissionCheck
): PermissionResult => {
  console.error(
    `[claude] auto-allowed ${toolName} escalated under bypassPermissions` +
      (check.agentID === undefined ? "" : ` agent=${check.agentID}`) +
      `: ${check.decisionReason ?? "no reason given"}`
  )
  return { behavior: "allow", updatedInput: toolInput }
}
