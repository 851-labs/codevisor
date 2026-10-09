import {
  sessionSkills,
  skillsUpdateEvent,
  SUPERSEDED_NATIVE_SKILLS
} from "@codevisor/agent-runtime"
import type { SessionSkill, SessionSkills, SessionSkillSource } from "@codevisor/api"

import type { ClaudeSession } from "./session.js"

/// Claude's `skillOverrides` setting that turns the superseded native skills
/// off. Synced skills are keyed by their bare name.
export const supersededSkillsOff: Readonly<Record<string, "off">> = Object.fromEntries(
  SUPERSEDED_NATIVE_SKILLS.map((name) => [name, "off" as const])
)

/// A row of `supportedCommands()` / `commands_changed`. Claude Code 2.1 also
/// sends `builtin` (true for its own rows), which the pinned SDK's types do
/// not declare yet.
export interface ClaudeSlashCommand {
  readonly name: string
  readonly description: string
  readonly aliases?: ReadonlyArray<string>
  readonly builtin?: boolean
}

/// Claude Code's own commands that are not skills. `supportedCommands()`
/// lists them together with skills, and only the `init` message (sent with
/// the first turn) tells them apart: what it lists in `slash_commands` but
/// not in `skills`. Until this server has seen an `init` from a CLI, this
/// snapshot (Claude Code 2.1, plus commands from earlier releases) stands in.
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

/// Which slash commands are Claude Code's own, per Claude executable.
export interface ClaudeCommandCatalog {
  readonly builtinCommands: (claudePath: string) => ReadonlySet<string>
  /// Records the built-in commands an `init` message reveals, so this and
  /// later sessions of the same CLI classify their command lists exactly.
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
      // Only rows the CLI marks as its own are learned, so one project's
      // custom commands never hide another project's skills. A CLI without
      // the marker can't say which rows are its own.
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
    // Claude Code appends where a skill was loaded from to its description.
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

/// The skills among Claude Code's slash commands: everything except its own
/// commands, hidden `__` commands, and MCP prompts.
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

/// A session's slash commands and the skills among them.
export interface ClaudeSkills {
  /// The Claude executable, and what the provider knows about which of its
  /// commands are built-in commands rather than skills.
  readonly claudePath: string
  readonly catalog: ClaudeCommandCatalog
  /// The latest command list, once the CLI has answered `supportedCommands()`.
  commands: ReadonlyArray<ClaudeSlashCommand> | undefined
  /// The skills last derived from `commands`.
  snapshot: SessionSkills | undefined
}

/// Starts tracking a new session's skills. The command list comes from the
/// same initialize response as the model list, so it is ready by the time
/// that one is; a late answer still lands, as a skills update.
export const trackClaudeSkills = (session: ClaudeSession): void => {
  session.q.supportedCommands().then(
    (commands) => updateClaudeCommands(session, commands),
    () => undefined
  )
}

/// `init` (sent with the first turn) says exactly which commands are skills:
/// learn the CLI's own commands and correct the startup classification.
export const learnClaudeSkills = (
  session: ClaudeSession,
  init: Parameters<ClaudeCommandCatalog["learn"]>[1]
): void => {
  const { catalog, claudePath, commands } = session.skills
  catalog.learn(claudePath, init, commands ?? [])
  publishClaudeSkills(session)
}

/// Replaces the session's command list and publishes its skills when they
/// changed.
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
