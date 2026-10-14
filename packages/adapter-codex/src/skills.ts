import { sessionSkills, skillsUpdateEvent } from "@codevisor/agent-runtime"
import type { SessionSkill, SessionSkillSource } from "@codevisor/api"

import { isRecord } from "./internal.js"
import type { CodexSession } from "./session.js"

export const NATIVE_CODEX_PLUGIN_SKILL_NAMES = [
  "browser:control-in-app-browser",
  "chrome:control-chrome",
  "computer-use:computer-use",
  "documents:documents",
  "pdf:pdf",
  "presentations:Presentations",
  "sites:sites-building",
  "sites:sites-hosting",
  "spreadsheets:Spreadsheets",
  "spreadsheets:excel-live-control",
  "template-creator:template-creator",
  "visualize:visualize"
] as const

export const DISABLED_CODEX_PLUGIN = "unified-computer-use@openai-bundled"

const DISABLED_SKILL_NAMES: ReadonlySet<string> = new Set(NATIVE_CODEX_PLUGIN_SKILL_NAMES)

const SCOPE_SOURCES: Readonly<Record<string, SessionSkillSource>> = {
  repo: "project",
  user: "user"
}

const trimmedText = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() !== "" ? value.trim() : undefined

export interface CodexSkill extends SessionSkill {
  readonly path: string
}

export const codexSkillsFrom = (response: unknown): ReadonlyArray<CodexSkill> => {
  const data = isRecord(response) && Array.isArray(response.data) ? response.data : []
  const entry = data.find(isRecord)
  const skills = entry !== undefined && Array.isArray(entry.skills) ? entry.skills : []
  return skills.flatMap((skill): Array<CodexSkill> => {
    if (!isRecord(skill) || skill.enabled === false) return []
    const name = trimmedText(skill.name)
    const path = trimmedText(skill.path)
    if (name === undefined || path === undefined) return []
    if (skill.scope === "system" || DISABLED_SKILL_NAMES.has(name)) return []
    const pluginId = trimmedText(skill.pluginId)
    if (pluginId === DISABLED_CODEX_PLUGIN) return []
    const ui = isRecord(skill.interface) ? skill.interface : {}
    const description =
      trimmedText(ui.shortDescription) ??
      trimmedText(skill.shortDescription) ??
      trimmedText(skill.description)
    const source =
      pluginId === undefined
        ? typeof skill.scope === "string"
          ? SCOPE_SOURCES[skill.scope]
          : undefined
        : "plugin"
    return [
      {
        invocation: `$${name}`,
        name,
        path,
        ...(description === undefined ? {} : { description }),
        ...(source === undefined ? {} : { source })
      }
    ]
  })
}

export const refreshCodexSkills = async (
  session: CodexSession,
  forceReload: boolean
): Promise<void> => {
  let skills: ReadonlyArray<CodexSkill>
  try {
    skills = codexSkillsFrom(
      await session.client.request("skills/list", {
        cwds: [session.cwd],
        ...(forceReload ? { forceReload: true } : {})
      })
    )
  } catch {
    return
  }
  const previous = session.skills
  session.skills = skills
  if (JSON.stringify(previous) === JSON.stringify(skills)) return
  void session.emit(skillsUpdateEvent(session.key, codexSessionSkills(skills)))
}

export const codexSessionSkills = (skills: ReadonlyArray<CodexSkill>) =>
  sessionSkills(
    skills.map(({ path: _path, ...skill }) => skill),
    "$"
  )

const SKILL_MENTION = /(?:^|\s)\$([\w.:-]+)/g

export const mentionedCodexSkills = (
  text: string,
  skills: ReadonlyArray<CodexSkill>
): ReadonlyArray<CodexSkill> => {
  const byName = new Map(skills.map((skill) => [skill.name, skill]))
  const mentioned = new Map<string, CodexSkill>()
  for (const match of text.matchAll(SKILL_MENTION)) {
    const token = match[1] ?? ""
    const skill = byName.get(token) ?? byName.get(token.replace(/[.:-]+$/, ""))
    if (skill !== undefined) mentioned.set(skill.name, skill)
  }
  return [...mentioned.values()]
}
