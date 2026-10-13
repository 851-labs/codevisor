import { sessionSkills, withAttachmentNotes, type PromptInput } from "@codevisor/agent-runtime"
import type { SessionSkill, SessionSkills } from "@codevisor/api"

import { record, text } from "./protocol.js"

/// Session-level MSP notifications (usage, todos, skills) and the prompt
/// shape, as Codevisor payloads.

const finite = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined

const defined = (fields: Record<string, number | undefined>): Record<string, number> =>
  Object.fromEntries(
    Object.entries(fields).filter((entry): entry is [string, number] => entry[1] !== undefined)
  )

/// `session/tokenUsage`: the session's running totals.
export const tokenUsageUpdate = (params: unknown): Record<string, unknown> => {
  const event = record(params)
  const usage = record(event.usage)
  const cumulative = record(event.cumulative)
  return {
    sessionUpdate: "usage_update",
    ...defined({
      // The latest model call's prompt plus reply: what the context holds.
      used: finite(event.totalTokens),
      inputTokens: finite(cumulative.promptTokens),
      outputTokens: finite(cumulative.outputTokens),
      totalTokens: finite(cumulative.totalTokens),
      cachedInputTokens: finite(usage.cacheReadTokens) ?? finite(usage.cachedTokens),
      reasoningOutputTokens: finite(usage.reasoningTokens)
    })
  }
}

/// `session/contextUsage`: how full the context window is.
export const contextUsageUpdate = (params: unknown): Record<string, unknown> => {
  const event = record(params)
  return {
    sessionUpdate: "usage_update",
    ...defined({ used: finite(event.usedTokens), size: finite(event.windowTokens) })
  }
}

const planStatus = (status: unknown): string | undefined => {
  switch (status) {
    case "pending":
      return "pending"
    case "inProgress":
      return "in_progress"
    case "completed":
      return "completed"
    default:
      // Cancelled todos leave the checklist.
      return undefined
  }
}

/// `session/todoListChanged`: a full replacement of the checklist.
export const planUpdate = (params: unknown): Record<string, unknown> => {
  const items = record(params).items
  return {
    sessionUpdate: "plan",
    entries: (Array.isArray(items) ? items : []).flatMap((entry) => {
      const item = record(entry)
      const status = planStatus(item.status)
      const content = text(item.text)
      return status === undefined || content === undefined
        ? []
        : [{ content, priority: "medium", status }]
    })
  }
}

/// `skill/list`: each skill runs as `/<selector>`.
export const museSkills = (response: unknown): SessionSkills => {
  const rows = record(response).skills
  return sessionSkills(
    (Array.isArray(rows) ? rows : []).flatMap((entry): Array<SessionSkill> => {
      const row = record(entry)
      const selector = text(row.selector)
      if (selector === undefined) return []
      const description = text(row.description)?.trim()
      const source = row.source === "user" || row.source === "project" ? row.source : undefined
      return [
        {
          invocation: `/${selector}`,
          name: text(row.displayName) ?? selector,
          ...(description === undefined || description === "" ? {} : { description }),
          ...(source === undefined ? {} : { source })
        }
      ]
    }),
    "/"
  )
}

/// The `turn/start` input: a leading `/<skill>` becomes a skill part (Muse
/// expands it host-side), images go inline, other attachments as path notes.
export const turnInput = (
  input: PromptInput,
  skills: ReadonlyArray<SessionSkill>
): Array<Record<string, unknown>> => {
  const attachments = input.attachments ?? []
  const images = attachments.flatMap((attachment) =>
    attachment.kind === "image" && attachment.inline !== undefined
      ? [
          {
            type: "image",
            base64Data: attachment.inline.data.toString("base64"),
            mediaType: attachment.inline.mimeType
          }
        ]
      : []
  )
  const noted = attachments.filter(
    (attachment) => attachment.kind !== "image" || attachment.inline === undefined
  )
  const prompt = withAttachmentNotes(input.text, noted)
  const invoked = /^\/(\S+)(?:\s+([\s\S]*))?$/.exec(prompt.trim())
  const skill =
    invoked === null ? undefined : skills.find((entry) => entry.invocation === `/${invoked[1]}`)
  if (skill !== undefined) {
    const args = invoked![2]?.trim()
    return [
      {
        type: "skill",
        selector: skill.invocation.slice(1),
        ...(args === undefined || args === "" ? {} : { arguments: args })
      },
      ...images
    ]
  }
  return [...(prompt.length === 0 ? [] : [{ type: "text", text: prompt }]), ...images]
}
