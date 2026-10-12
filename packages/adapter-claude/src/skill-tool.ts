import type { CodevisorSkillRead } from "@codevisor/api"

import { isRecord } from "./internal.js"
import type { ClaudeSession } from "./session.js"

/// Claude Code's own `Skill` tool, presented the way a Codevisor skill read
/// is: the row is annotated `_meta.codevisorSkill`, and its body is the
/// skill's instructions. Claude Code answers the call with only
/// "Launching skill: name"; the instructions follow in a synthetic user
/// message ("Base directory for this skill: …", then SKILL.md), which
/// carries no tool id, so it is matched to the call by the skill's name.

export const SKILL_TOOL = "Skill"

/// What Claude Code prefixes a loaded skill's instructions with.
const SKILL_TEXT_PREFIX = "Base directory for this skill:"

export interface ClaudeSkillCall {
  readonly name: string
  readonly parentId: string | undefined
  /// The call returned, so its instructions are expected next.
  resulted: boolean
}

const skillMeta = (name: string, ok: boolean): { readonly codevisorSkill: CodevisorSkillRead } => ({
  codevisorSkill: { name, ok }
})

/// The `_meta` a `Skill` call's input update carries, and records the call
/// so its result and instructions can be attached to it.
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

/// The `_meta` a `Skill` call's result carries. A failed call expects no
/// instructions.
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

/// The skill a loaded-instructions message belongs to: the returned call
/// whose name matches the skill's folder, else the oldest one waiting.
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

/// Attaches a synthetic message's skill instructions to the `Skill` call
/// that loaded them. Returns whether the message was a skill's
/// instructions, which then need no other handling.
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
