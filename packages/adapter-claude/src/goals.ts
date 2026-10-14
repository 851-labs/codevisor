import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"
import { isoTimestamp, type SessionGoal } from "@codevisor/api"

import type { ClaudeSession } from "./session.js"

export const settleGoalOnTurnEnd = (
  session: ClaudeSession,
  message: SDKMessage & { type: "result" }
): void => {
  const goal = session.currentGoal
  if (goal === undefined || goal.status !== "active") return
  const status = session.interruptRequested
    ? "paused"
    : message.subtype === "success"
      ? "complete"
      : "blocked"
  const settled: SessionGoal = { ...goal, status, updatedAt: isoTimestamp() }
  session.currentGoal = settled
  void session.emit({
    kind: "session.updated",
    payload: { goal: settled },
    subjectId: session.key
  })
}

export const pauseGoalForForcedCancellation = async (session: ClaudeSession): Promise<void> => {
  const goal = session.currentGoal
  if (goal === undefined || goal.status !== "active") return
  const settled: SessionGoal = { ...goal, status: "paused", updatedAt: isoTimestamp() }
  session.currentGoal = settled
  await session.emit({
    kind: "session.updated",
    payload: { goal: settled },
    subjectId: session.key
  })
}

export const pushGoalCommand = (session: ClaudeSession, command: string): void => {
  session.pendingUserCommands += 1
  session.input.push({
    message: { content: [{ text: command, type: "text" }], role: "user" },
    parent_tool_use_id: null,
    session_id: session.sdkSessionId,
    type: "user"
  })
}
