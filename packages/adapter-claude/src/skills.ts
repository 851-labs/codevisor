import {
  sessionSkills,
  skillsUpdateEvent,
  SUPERSEDED_NATIVE_SKILLS
} from "@codevisor/agent-runtime"
import type { SessionSkill, SessionSkills, SessionSkillSource } from "@codevisor/api"

import type { ClaudeSession } from "./session.js"

export const supersededSkillsOff: Readonly<Record<string, "off">> = Object.fromEntries(
  SUPERSEDED_NATIVE_SKILLS.map((name) => [name, "off" as const])
)

export interface ClaudeSlashCommand {
  readonly name: string
  readonly description: string
  readonly aliases?: ReadonlyArray<string>
  readonly builtin?: boolean
}

const KNOWN_BUILTIN_COMMANDS: ReadonlySet<string> = new Set([
  "add-dir",
  "advisor",
  "agents",
  "auto-mode-setup",
  "autocompact",
  "bashes",
  "bug",
  "clear",
  "color",
  "compact",
  "config",
  "context",
  "cost",
  "design-consent",
  "design-revoke",
  "effort",
  "exit",
  "export",
  "extra-usage",
  "fast",
  "focus",
  "goal",
  "heapdump",
  "help",
  "hooks",
  "ide",
  "import",
  "init",
  "insights",
  "install-github-app",
  "list-agents",
  "login",
  "logout",
  "mcp",
  "memory",
  "model",
  "output-style",
  "permissions",
  "plan",
  "plugin",
  "pr-comments",
  "privacy-settings",
  "recap",
  "release-notes",
  "reload-plugins",
  "reload-skills",
  "rename",
  "resume",
  "rewind",
  "sandbox",
  "security-review",
  "skill-doctor",
  "stats",
  "status",
  "statusline",
  "tasks",
  "team-onboarding",
  "terminal-setup",
  "todos",
  "upgrade",
  "usage",
  "usage-credits",
  "vim",
  "workflow-launch-exec"
])

export interface ClaudeCommandCatalog {
  readonly builtinCommands: (claudePath: string) => ReadonlySet<string>
  readonly learn: (
    claudePath: string,
    init: {
      readonly slash_commands?: ReadonlyArray<string>
      readonly skills?: ReadonlyArray<string>
    },
    commands: ReadonlyArray<ClaudeSlashCommand>
  ) => void
}

export const makeClaudeCommandCatalog = (): ClaudeCommandCatalog => {
  const learned = new Map<string, ReadonlySet<string>>()
  return {
    builtinCommands: (claudePath) => learned.get(claudePath) ?? KNOWN_BUILTIN_COMMANDS,
    learn: (claudePath, init, commands) => {
      if (init.slash_commands === undefined || init.skills === undefined) return
      const skills = new Set(init.skills)
      const marked = commands.some((command) => command.builtin !== undefined)
      const own = new Set(
        commands.filter((command) => command.builtin === true).map((command) => command.name)
      )
      learned.set(
        claudePath,
        new Set(
          init.slash_commands.filter((name) => !skills.has(name) && (!marked || own.has(name)))
        )
      )
    }
  }
}

const SOURCE_SUFFIXES: ReadonlyArray<readonly [string, SessionSkillSource]> = [
  [" (project)", "project"],
  [" (user)", "user"]
]

const skillFor = (command: ClaudeSlashCommand): SessionSkill => {
  let description = command.description.trim()
  let source: SessionSkillSource | undefined
  if (command.builtin === true) {
    source = "builtin"
  } else {
    for (const [suffix, suffixSource] of SOURCE_SUFFIXES) {
      if (description.endsWith(suffix)) {
        description = description.slice(0, -suffix.length).trimEnd()
        source = suffixSource
        break
      }
    }
    if (source === undefined && command.name.includes(":")) source = "plugin"
  }
  return {
    invocation: `/${command.name}`,
    name: command.name,
    ...(description === "" ? {} : { description }),
    ...(source === undefined ? {} : { source })
  }
}

export const claudeSkills = (
  commands: ReadonlyArray<ClaudeSlashCommand>,
  builtinCommands: ReadonlySet<string>
): SessionSkills =>
  sessionSkills(
    commands
      .filter(
        (command) =>
          !builtinCommands.has(command.name) &&
          !command.name.startsWith("__") &&
          !command.name.endsWith(" (MCP)")
      )
      .map(skillFor),
    "/"
  )

export interface ClaudeSkills {
  readonly claudePath: string
  readonly catalog: ClaudeCommandCatalog
  commands: ReadonlyArray<ClaudeSlashCommand> | undefined
  snapshot: SessionSkills | undefined
}

export const trackClaudeSkills = (session: ClaudeSession): void => {
  session.q.supportedCommands().then(
    (commands) => updateClaudeCommands(session, commands),
    () => undefined
  )
}

export const learnClaudeSkills = (
  session: ClaudeSession,
  init: Parameters<ClaudeCommandCatalog["learn"]>[1]
): void => {
  const { catalog, claudePath, commands } = session.skills
  catalog.learn(claudePath, init, commands ?? [])
  publishClaudeSkills(session)
}

export const updateClaudeCommands = (
  session: ClaudeSession,
  commands: ReadonlyArray<ClaudeSlashCommand>
): void => {
  session.skills.commands = commands
  publishClaudeSkills(session)
}

const publishClaudeSkills = (session: ClaudeSession): void => {
  const { catalog, claudePath, commands } = session.skills
  if (commands === undefined) return
  const skills = claudeSkills(commands, catalog.builtinCommands(claudePath))
  if (JSON.stringify(skills) === JSON.stringify(session.skills.snapshot)) return
  session.skills.snapshot = skills
  if (session.retired) return
  void session.emit(skillsUpdateEvent(session.key, skills)).catch(() => undefined)
}
