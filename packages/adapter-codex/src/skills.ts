import { sessionSkills, skillsUpdateEvent } from "@codevisor/agent-runtime"
import type { SessionSkill, SessionSkillSource } from "@codevisor/api"

import { isRecord } from "./internal.js"
import type { CodexSession } from "./session.js"

/// Codex's first-party plugin skills, which Codevisor-owned threads turn off
/// (see start-session.ts): Codevisor's own browser and computer tools replace
/// them.
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

/// A plugin Codevisor-owned threads turn off as a whole.
export const DISABLED_CODEX_PLUGIN = "unified-computer-use@openai-bundled"

const DISABLED_SKILL_NAMES: ReadonlySet<string> = new Set(NATIVE_CODEX_PLUGIN_SKILL_NAMES)

const SCOPE_SOURCES: Readonly<Record<string, SessionSkillSource>> = {
  repo: "project",
  user: "user"
}

const text = (value: unknown): string | undefined =>
  typeof value === "string" && value.trim() !== "" ? value.trim() : undefined

/// A Codex skill the thread can run, with the SKILL.md path `turn/start`
/// takes to load it directly.
export interface CodexSkill extends SessionSkill {
  readonly path: string
}

/// The skills in a `skills/list` answer for one directory. `skills/list`
/// reads the user's global config, so the thread config's overrides
/// (bundled `system` skills and first-party plugins off) are applied here.
export const codexSkillsFrom = (response: unknown): ReadonlyArray<CodexSkill> => {
  const data = isRecord(response) && Array.isArray(response.data) ? response.data : []
  const entry = data.find(isRecord)
  const skills = entry !== undefined && Array.isArray(entry.skills) ? entry.skills : []
  return skills.flatMap((skill): Array<CodexSkill> => {
    if (!isRecord(skill) || skill.enabled === false) return []
    const name = text(skill.name)
    const path = text(skill.path)
    if (name === undefined || path === undefined) return []
    if (skill.scope === "system" || DISABLED_SKILL_NAMES.has(name)) return []
    const pluginId = text(skill.pluginId)
    if (pluginId === DISABLED_CODEX_PLUGIN) return []
    const ui = isRecord(skill.interface) ? skill.interface : {}
    const description =
      text(ui.shortDescription) ?? text(skill.shortDescription) ?? text(skill.description)
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

/// Re-lists the thread directory's skills and publishes them when they
/// changed. Codex servers without `skills/list` keep an empty list.
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

/// The client-facing snapshot: Codex invokes every skill as `$name`.
export const codexSessionSkills = (skills: ReadonlyArray<CodexSkill>) =>
  sessionSkills(
    skills.map(({ path: _path, ...skill }) => skill),
    "$"
  )

const SKILL_MENTION = /(?:^|\s)\$([\w.:-]+)/g

/// The skills a prompt invokes by `$name`. `turn/start` takes each as a
/// `skill` item next to the text so Codex loads its SKILL.md up front instead
/// of having the model look for it.
export const mentionedCodexSkills = (
  text: string,
  skills: ReadonlyArray<CodexSkill>
): ReadonlyArray<CodexSkill> => {
  const byName = new Map(skills.map((skill) => [skill.name, skill]))
  const mentioned = new Map<string, CodexSkill>()
  for (const match of text.matchAll(SKILL_MENTION)) {
    const token = match[1] ?? ""
    // Trailing punctuation ends a sentence, not the name.
    const skill = byName.get(token) ?? byName.get(token.replace(/[.:-]+$/, ""))
    if (skill !== undefined) mentioned.set(skill.name, skill)
  }
  return [...mentioned.values()]
}
