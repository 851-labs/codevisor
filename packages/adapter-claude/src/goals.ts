import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"
import { isoTimestamp, type SessionGoal } from "@codevisor/api"
import type { ClaudeSession } from "./session.js"

/// The SDK stream carries no goal-state messages, so completion is inferred:
/// in non-interactive mode the `/goal` command runs the whole goal loop
/// inside one turn, so that turn's result settles the goal — success marks
/// it complete, an interrupt pauses it (resumable), a failure blocks it.
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

/// Sends a `/goal` slash command as a user message — the SDK forwards it to
/// the CLI, which executes it exactly like typing it interactively (goal mode
/// has no SDK API yet). The CLI's reply narrates the outcome in the chat.
export const pushGoalCommand = (session: ClaudeSession, command: string): void => {
  session.pendingUserCommands += 1
  session.input.push({
    message: { content: [{ text: command, type: "text" }], role: "user" },
    parent_tool_use_id: null,
    session_id: session.sdkSessionId,
    type: "user"
  })
}
