import type { CodevisorSkillRead } from "@codevisor/api"

import { record } from "./internal.js"

type JsonRecord = Readonly<Record<string, unknown>>

const SKILL_CONTENT = "<skill_content"
const BASE_DIRECTORY = "\nBase directory for this skill:"

const instructions = (output: string): string => {
  const lines = output.split("\n")
  const body = lines.slice(lines[1]?.startsWith("# Skill:") === true ? 2 : 1).join("\n")
  const end = body.indexOf(BASE_DIRECTORY)
  return (end === -1 ? body.replace(/<\/skill_content>\s*$/, "") : body.slice(0, end)).trim()
}

export const skillReadUpdate = (update: JsonRecord): JsonRecord => {
  if (update.sessionUpdate !== "tool_call" && update.sessionUpdate !== "tool_call_update")
    return update
  const rawOutput = record(update.rawOutput)
  const output = typeof rawOutput?.output === "string" ? rawOutput.output : undefined
  const loaded = output?.startsWith(SKILL_CONTENT) === true
  const input = update.title === "skill" ? record(update.rawInput)?.name : undefined
  const name = loaded ? record(rawOutput?.metadata)?.name : input
  if (typeof name !== "string" || name === "") return update
  const skill: CodevisorSkillRead = { name, ok: update.status !== "failed" }
  const meta = { ...record(update._meta), codevisorSkill: skill }
  if (!loaded || output === undefined) return { ...update, _meta: meta }
  const text = instructions(output)
  return {
    ...update,
    _meta: meta,
    content: [{ type: "content", content: { type: "text", text } }],
    rawOutput: text
  }
}

export const withSkillRead = (value: unknown): unknown => {
  const message = record(value)
  const update = record(message?.update)
  return update === undefined ? value : { ...message, update: skillReadUpdate(update) }
}
