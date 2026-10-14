import type { CodevisorSkillRead } from "@codevisor/api"

import { isRecord } from "./internal.js"
import type { ClaudeSession } from "./session.js"

export const SKILL_TOOL = "Skill"

const SKILL_TEXT_PREFIX = "Base directory for this skill:"

export interface ClaudeSkillCall {
  readonly name: string
  readonly parentId: string | undefined
  resulted: boolean
}

const skillMeta = (name: string, ok: boolean): { readonly codevisorSkill: CodevisorSkillRead } => ({
  codevisorSkill: { name, ok }
})

export const skillCallMeta = (
  session: ClaudeSession,
  toolUseId: string,
  input: unknown,
  parentId: string | undefined
): { readonly _meta: ReturnType<typeof skillMeta> } | undefined => {
  const name = isRecord(input) && typeof input.skill === "string" ? input.skill.trim() : ""
  if (name === "") return undefined
  session.skillCalls.set(toolUseId, { name, parentId, resulted: false })
  return { _meta: skillMeta(name, true) }
}

export const skillResultMeta = (
  session: ClaudeSession,
  toolUseId: string,
  failed: boolean
): { readonly _meta: ReturnType<typeof skillMeta> } | undefined => {
  const call = session.skillCalls.get(toolUseId)
  if (call === undefined) return undefined
  if (failed) session.skillCalls.delete(toolUseId)
  else call.resulted = true
  return { _meta: skillMeta(call.name, !failed) }
}

const awaitingCall = (
  session: ClaudeSession,
  folder: string
): [string, ClaudeSkillCall] | undefined => {
  const waiting = [...session.skillCalls].filter(([, call]) => call.resulted)
  return (
    waiting.find(([, call]) => call.name === folder || call.name.endsWith(`:${folder}`)) ??
    waiting[0]
  )
}

export const attachSkillText = (
  session: ClaudeSession,
  content: ReadonlyArray<unknown>
): boolean => {
  const text = content
    .map((block) => (isRecord(block) && typeof block.text === "string" ? block.text : ""))
    .join("")
  if (!text.startsWith(SKILL_TEXT_PREFIX)) return false
  const [header = "", ...body] = text.split("\n")
  const folder = header.slice(SKILL_TEXT_PREFIX.length).trim().split("/").findLast(Boolean) ?? ""
  const matched = awaitingCall(session, folder)
  if (matched === undefined) return true
  const [toolUseId, call] = matched
  session.skillCalls.delete(toolUseId)
  const instructions = body.join("\n").trim()
  void session.emit({
    kind: "session.output",
    payload: {
      _meta: skillMeta(call.name, true),
      content: [{ type: "content", content: { type: "text", text: instructions } }],
      rawOutput: instructions,
      sessionUpdate: "tool_call_update",
      toolCallId: toolUseId,
      ...(call.parentId === undefined ? {} : { parentToolCallId: call.parentId })
    },
    subjectId: session.key
  })
  return true
}
