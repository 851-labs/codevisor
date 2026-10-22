import { readdir, readFile } from "node:fs/promises"
import { dirname, join, resolve } from "node:path"

import { sessionSkills } from "@codevisor/agent-runtime"
import type { SessionSkill, SessionSkillSource, SessionSkills } from "@codevisor/api"

export interface AcpAvailableCommand {
  readonly name: string
  readonly description?: string | null
  readonly _meta?: Record<string, unknown> | null
}

const PROJECT_SKILL_DIRS = [
  ".agents/skills",
  ".claude/skills",
  ".cursor/skills",
  ".github/skills",
  ".grok/skills",
  ".opencode/skill",
  ".opencode/skills"
]

const USER_SKILL_DIRS = [
  ".agents/skills",
  ".claude/skills",
  ".config/opencode/skill",
  ".config/opencode/skills",
  ".copilot/skills",
  ".cursor/skills",
  ".grok/skills"
]

const GROK_SCOPES: Readonly<Record<string, SessionSkillSource>> = {
  bundled: "builtin",
  local: "project",
  plugin: "plugin",
  repo: "project",
  server: "user",
  user: "user"
}

const frontmatterName = (content: string): string | undefined => {
  const block = /^---\r?\n([\s\S]*?)\r?\n---/.exec(content)?.[1]
  const name = block
    ?.match(/^name:\s*(.+)$/m)?.[1]
    ?.trim()
    .replace(/^["']|["']$/g, "")
  return name === undefined || name === "" ? undefined : name
}

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
  for (const name of project.flat()) if (!sources.has(name)) sources.set(name, "project")
  for (const name of user.flat()) if (!sources.has(name)) sources.set(name, "user")
  return sources
}

const SOURCE_SUFFIX = /\s*\((?:project|user|global) skill\)$/i

const metaText = (meta: Record<string, unknown> | null | undefined, key: string) =>
  typeof meta?.[key] === "string" ? meta[key] : undefined

const declaredSkillSource = (scope: string | undefined) => {
  if (scope === undefined) return undefined
  return GROK_SCOPES[scope]
}

export const acpSkills = (
  commands: ReadonlyArray<AcpAvailableCommand>,
  skillFolders: ReadonlyMap<string, SessionSkillSource>
): SessionSkills =>
  sessionSkills(
    commands.flatMap((command): Array<SessionSkill> => {
      const scope = metaText(command._meta, "scope")
      const declared = metaText(command._meta, "path") !== undefined
      if (!declared && !skillFolders.has(command.name)) return []
      const source = declared ? declaredSkillSource(scope) : skillFolders.get(command.name)
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

export interface AcpSkillTracker {
  readonly update: (
    sessionId: string,
    commands: ReadonlyArray<AcpAvailableCommand>
  ) => Promise<SessionSkills | undefined>
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
