import type * as acp from "@agentclientprotocol/sdk"
import type { DiffStat } from "@codevisor/api"
import { diffStatsFromTexts, type RuntimeEvent } from "@codevisor/agent-runtime"

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
export const runtimeEventFromNotification = (
  notification: acp.SessionNotification
): RuntimeEvent => {
  const update = notification.update
  switch (update.sessionUpdate) {
    case "user_message_chunk":
    case "agent_message_chunk":
    case "agent_thought_chunk":
    case "plan":
    case "available_commands_update":
      return {
        kind: "session.output",
        subjectId: notification.sessionId,
        payload: update
      }
    case "tool_call":
    case "tool_call_update":
      return {
        kind: "session.output",
        subjectId: notification.sessionId,
        payload: withDiffStats(update)
      }
    case "session_info_update":
    case "usage_update":
      return {
        kind: "session.updated",
        subjectId: notification.sessionId,
        payload: update
      }
    default:
      return {
        kind: "session.output",
        subjectId: notification.sessionId,
        payload: update
      }
  }
}

/// ACP adapters deliver diffs only at completion; attach the added/removed
/// line counts so clients can render the +N/−N header without re-diffing.
const withDiffStats = (update: { readonly content?: unknown }): Record<string, unknown> => {
  const content = update.content
  if (!Array.isArray(content)) {
    return update as Record<string, unknown>
  }
  const stats: Array<DiffStat> = []
  for (const block of content) {
    if (
      typeof block === "object" &&
      block !== null &&
      (block as { type?: unknown }).type === "diff"
    ) {
      const diff = block as { path?: unknown; oldText?: unknown; newText?: unknown }
      if (typeof diff.path === "string" && typeof diff.newText === "string") {
        stats.push(
          diffStatsFromTexts(
            diff.path,
            typeof diff.oldText === "string" ? diff.oldText : undefined,
            diff.newText
          )
        )
      }
    }
  }
  return stats.length === 0
    ? (update as Record<string, unknown>)
    : { ...(update as Record<string, unknown>), diffStats: stats }
}
/* v8 ignore stop */
