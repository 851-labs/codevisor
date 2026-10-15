import { diffStatsFromTexts, type RuntimeEvent } from "@codevisor/agent-runtime"
import { isRecord, type DiffStat } from "@codevisor/api"

import { normalizeAcpConfigOptions } from "./config-options.js"

export interface AcpUpdateNotification {
  readonly sessionId: string
  readonly update: Readonly<Record<string, unknown>>
}

const withNormalizedConfigOptions = (
  update: Readonly<Record<string, unknown>>
): Readonly<Record<string, unknown>> => {
  if (update.sessionUpdate !== "config_option_update" || !Array.isArray(update.configOptions)) {
    return update
  }
  return {
    ...update,
    configOptions: normalizeAcpConfigOptions(update.configOptions)
  }
}

/* v8 ignore start */
export const runtimeEventFromNotification = (notification: AcpUpdateNotification): RuntimeEvent => {
  const update = withNormalizedConfigOptions(notification.update)
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

const withDiffStats = (
  update: Readonly<Record<string, unknown>>
): Readonly<Record<string, unknown>> => {
  const content = update.content
  if (!Array.isArray(content)) {
    return update
  }
  const stats: Array<DiffStat> = []
  for (const block of content) {
    if (
      isRecord(block) &&
      block.type === "diff" &&
      typeof block.path === "string" &&
      typeof block.newText === "string"
    ) {
      stats.push(
        diffStatsFromTexts(
          block.path,
          typeof block.oldText === "string" ? block.oldText : undefined,
          block.newText
        )
      )
    }
  }
  return stats.length === 0 ? update : { ...update, diffStats: stats }
}
/* v8 ignore stop */
