import type { CodevisorSkillRead } from "@codevisor/api"

/// OpenCode's own `skill` tool, presented the way a Codevisor skill read is:
/// annotated `_meta.codevisorSkill`, with the skill's instructions as its
/// output. OpenCode titles the call `skill`, then `Loaded skill: name`, and
/// returns the instructions wrapped for the model:
///
///   <skill_content name="x">
///   # Skill: x
///
///   …SKILL.md…
///
///   Base directory for this skill: /…
///   …a sampled file list…
///   </skill_content>
///
/// The completed update carries no input, so the name then comes from the
/// output's metadata.

type JsonRecord = Readonly<Record<string, unknown>>

const record = (value: unknown): JsonRecord | undefined =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as JsonRecord)
    : undefined

const SKILL_CONTENT = "<skill_content"
const BASE_DIRECTORY = "\nBase directory for this skill:"

/// The skill's own instructions from OpenCode's wrapped output.
const instructions = (output: string): string => {
  const lines = output.split("\n")
  // Drop the `<skill_content …>` line and the `# Skill: name` heading.
  const body = lines.slice(lines[1]?.startsWith("# Skill:") === true ? 2 : 1).join("\n")
  const end = body.indexOf(BASE_DIRECTORY)
  return (end === -1 ? body.replace(/<\/skill_content>\s*$/, "") : body.slice(0, end)).trim()
}

/// `update` rewritten as a skill read when it is OpenCode's `skill` tool;
/// any other update unchanged.
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

/// A notification-shaped value (`{ update }`) with its update rewritten.
export const withSkillRead = <T>(value: T): T => {
  const update = record(record(value)?.update)
  return update === undefined ? value : ({ ...value, update: skillReadUpdate(update) } as T)
}
