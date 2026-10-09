import { readdir, readFile } from "node:fs/promises"
import { dirname, join, resolve } from "node:path"

import { sessionSkills } from "@codevisor/agent-runtime"
import type { SessionSkill, SessionSkillSource, SessionSkills } from "@codevisor/api"

/// One `available_commands_update` row, as far as skills need it.
export interface AcpAvailableCommand {
  readonly name: string
  readonly description?: string | null
  readonly _meta?: Record<string, unknown> | null
}

/// Skill folders ACP agents read in a workspace and each of its parents.
const PROJECT_SKILL_DIRS = [
  ".agents/skills",
  ".claude/skills",
  ".cursor/skills",
  ".github/skills",
  ".grok/skills",
  ".opencode/skill",
  ".opencode/skills"
]

/// Skill folders ACP agents read in the user's home directory.
const USER_SKILL_DIRS = [
  ".agents/skills",
  ".claude/skills",
  ".config/opencode/skill",
  ".config/opencode/skills",
  ".copilot/skills",
  ".cursor/skills",
  ".grok/skills"
]

/// Grok Build reports where each skill was loaded from.
const GROK_SCOPES: Readonly<Record<string, SessionSkillSource>> = {
  bundled: "builtin",
  local: "project",
  plugin: "plugin",
  repo: "project",
  server: "user",
  user: "user"
}

/// The `name` a SKILL.md's frontmatter declares, if any.
const frontmatterName = (content: string): string | undefined => {
  const block = /^---\r?\n([\s\S]*?)\r?\n---/.exec(content)?.[1]
  const name = block
    ?.match(/^name:\s*(.+)$/m)?.[1]
    ?.trim()
    .replace(/^["']|["']$/g, "")
  return name === undefined || name === "" ? undefined : name
}

/// The skill names in one skills folder: each subfolder with a SKILL.md, by
/// folder name and by its frontmatter `name`.
const skillNamesIn = async (dir: string): Promise<ReadonlyArray<string>> => {
  let entries
  try {
    entries = await readdir(dir, { withFileTypes: true })
  } catch {
    return []
  }
  const names = await Promise.all(
    entries
      .filter((entry) => entry.isDirectory() || entry.isSymbolicLink())
      .map(async (entry) => {
        try {
          const content = await readFile(join(dir, entry.name, "SKILL.md"), "utf8")
          const declared = frontmatterName(content)
          return declared === undefined ? [entry.name] : [entry.name, declared]
        } catch {
          return []
        }
      })
  )
  return names.flat()
}

/// The skills on disk an ACP agent in `cwd` can see, and where each comes
/// from: the workspace and its parents up to (not including) the home folder
/// are the project's, the home folder's are the user's.
export const discoverSkillFolders = async (
  cwd: string,
  home: string | undefined
): Promise<ReadonlyMap<string, SessionSkillSource>> => {
  const projectDirs: Array<string> = []
  const homeDir = home === undefined ? undefined : resolve(home)
  let dir = resolve(cwd)
  while (dir !== homeDir) {
    projectDirs.push(...PROJECT_SKILL_DIRS.map((relative) => join(dir, relative)))
    const parent = dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  const userDirs =
    homeDir === undefined ? [] : USER_SKILL_DIRS.map((relative) => join(homeDir, relative))
  const [project, user] = await Promise.all([
    Promise.all(projectDirs.map(skillNamesIn)),
    Promise.all(userDirs.map(skillNamesIn))
  ])
  const sources = new Map<string, SessionSkillSource>()
  // The nearest folder wins, as it does for the agents themselves.
  for (const name of project.flat()) if (!sources.has(name)) sources.set(name, "project")
  for (const name of user.flat()) if (!sources.has(name)) sources.set(name, "user")
  return sources
}

/// Cursor ends each skill's description with where it came from, which the
/// palette already shows as the skill's source.
const SOURCE_SUFFIX = /\s*\((?:project|user|global) skill\)$/i

const metaText = (meta: Record<string, unknown> | null | undefined, key: string) =>
  typeof meta?.[key] === "string" ? meta[key] : undefined

/// The skills among an ACP agent's slash commands. ACP has no field that
/// tells a skill from a command: a row is a skill when the agent says where
/// its SKILL.md lives (Grok's `_meta.path`), or when its name matches a skill
/// folder on disk. Commands such as `/compact` or `/init` match neither.
export const acpSkills = (
  commands: ReadonlyArray<AcpAvailableCommand>,
  skillFolders: ReadonlyMap<string, SessionSkillSource>
): SessionSkills =>
  sessionSkills(
    commands.flatMap((command): Array<SessionSkill> => {
      const scope = metaText(command._meta, "scope")
      const declared = metaText(command._meta, "path") !== undefined
      if (!declared && !skillFolders.has(command.name)) return []
      const source = declared
        ? scope === undefined
          ? undefined
          : GROK_SCOPES[scope]
        : skillFolders.get(command.name)
      const description = (command.description ?? "").replace(SOURCE_SUFFIX, "").trim()
      return [
        {
          invocation: `/${command.name}`,
          name: command.name,
          ...(description === "" ? {} : { description }),
          ...(source === undefined ? {} : { source })
        }
      ]
    }),
    "/"
  )

/// Tracks each session's skills from its `available_commands_update`
/// notifications, so session setup can report them with its metadata.
export interface AcpSkillTracker {
  /// Classifies a session's latest command list. Resolves with the skills
  /// when they changed, or undefined when they did not or a newer list
  /// superseded this one.
  readonly update: (
    sessionId: string,
    commands: ReadonlyArray<AcpAvailableCommand>
  ) => Promise<SessionSkills | undefined>
  /// The session's skills, waiting up to `timeoutMs` for its first command
  /// list. Agents push the list right after session setup, not with it.
  readonly current: (sessionId: string, timeoutMs: number) => Promise<SessionSkills | undefined>
}

export const makeAcpSkillTracker = (
  discover: () => Promise<ReadonlyMap<string, SessionSkillSource>>
): AcpSkillTracker => {
  const latest = new Map<string, SessionSkills>()
  const revisions = new Map<string, number>()
  const waiters = new Map<string, Array<(skills: SessionSkills) => void>>()
  return {
    update: async (sessionId, commands) => {
      const revision = (revisions.get(sessionId) ?? 0) + 1
      revisions.set(sessionId, revision)
      const skills = acpSkills(commands, await discover())
      if (revisions.get(sessionId) !== revision) return undefined
      const previous = latest.get(sessionId)
      latest.set(sessionId, skills)
      for (const resolveWaiter of waiters.get(sessionId) ?? []) resolveWaiter(skills)
      waiters.delete(sessionId)
      return JSON.stringify(previous) === JSON.stringify(skills) ? undefined : skills
    },
    current: (sessionId, timeoutMs) => {
      const known = latest.get(sessionId)
      if (known !== undefined || timeoutMs <= 0) return Promise.resolve(known)
      return new Promise((resolveCurrent) => {
        const timer = setTimeout(() => {
          const pending = waiters.get(sessionId) ?? []
          waiters.set(
            sessionId,
            pending.filter((waiter) => waiter !== settle)
          )
          resolveCurrent(undefined)
        }, timeoutMs)
        const settle = (skills: SessionSkills) => {
          clearTimeout(timer)
          resolveCurrent(skills)
        }
        waiters.set(sessionId, [...(waiters.get(sessionId) ?? []), settle])
      })
    }
  }
}
