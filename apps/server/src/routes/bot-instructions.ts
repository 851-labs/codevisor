import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import type { Bot } from "@codevisor/api"
import { botPath } from "@codevisor/db"

import { run, type CodevisorServerServices } from "../server-context.js"

export interface BotRepository {
  readonly folderName: string
  readonly name: string
  readonly repoDir: string
  readonly projectId: string
}

const BOT_MESSAGING_SECTION: ReadonlyArray<string> = [
  "## Talking to the user",
  "",
  "The user chats with you like iMessage and only sees the messages you send with",
  "`machines.current.tools.codevisor.messages.send` through the Codevisor MCP. Nothing else you write reaches them, not",
  "even your final reply. Read the `codevisor-messages` skill before your first reply.",
  ""
]

const START_STEP =
  '1. `machines.current.agents.start({ project: projectId, isolation: "worktree", title, prompt })`'

const WAIT_FOLLOW_UP_STEP =
  "2. `machines.current.agents.status({ agentId })` or `machines.current.agents.wait({ agentIds })` to follow up"

const EVENT_FOLLOW_UP_STEP =
  "2. End your turn. When the agent finishes, Codevisor sends you a `<codevisor-event>` with its complete final reply"

const LEGACY_MESSAGING_LINE =
  "`codevisor.messages.send` through the Codevisor MCP. Nothing else you write reaches them, not"

const LEGACY_DELEGATION_STEPS: ReadonlyArray<RegExp> = [
  /^1\. `worktrees\.create\(\{ projectId \}\)`$/m,
  /^2\. `sessions\.create\(\{ projectId, worktreeName,.*\}\)`\n/m,
  /^3\. `sessions\.prompt\(\{ sessionId, text \}\)`\n/m,
  /^4\. `sessions\.wait` or `sessions\.get` to follow up$/m,
  /^4\. End your turn\. When the agent finishes, Codevisor sends you a `<codevisor-event>` with its result$/m
]

const REPOSITORIES_HEADING = "## Repositories"

const repositoriesSection = (repositories: ReadonlyArray<BotRepository>): ReadonlyArray<string> => [
  REPOSITORIES_HEADING,
  "",
  ...repositories.map(
    (repository) =>
      `- \`${repository.folderName}/\`: ${repository.name} ` +
      `(from \`${repository.repoDir}\`, projectId \`${repository.projectId}\`)`
  ),
  "",
  "When a task needs a repository that isn't listed, add it with",
  "`machines.current.tools.codevisor.bot.projects_add({ projectId })`, using a projectId from",
  "`projects.list`. Remove one you no longer need with `bot.projects_remove({ projectId })`.",
  ""
]

export const replaceRepositories = (
  text: string,
  repositories: ReadonlyArray<BotRepository>
): string => {
  const section = `${repositoriesSection(repositories).join("\n").trimEnd()}\n`
  const start = text.indexOf(`${REPOSITORIES_HEADING}\n`)
  if (start !== -1) {
    const next = text.indexOf("\n## ", start + REPOSITORIES_HEADING.length)
    return text.slice(0, start) + section + (next === -1 ? "" : `\n${text.slice(next + 1)}`)
  }
  const delegating = text.indexOf("## Delegating work")
  return delegating === -1
    ? `${text.trimEnd()}\n\n${section}`
    : `${text.slice(0, delegating)}${section}\n${text.slice(delegating)}`
}

export const botRepositories = async (
  services: CodevisorServerServices,
  bot: Bot
): Promise<ReadonlyArray<BotRepository>> => {
  const projects = await run(services.db.listProjects)
  return bot.projects.flatMap((checkout) => {
    const project = projects.find(
      (candidate) => candidate.id.toLowerCase() === checkout.projectId.toLowerCase()
    )
    const location = project?.locations.find((candidate) => candidate.serverId === bot.serverId)
    /* v8 ignore next */
    if (project === undefined || location === undefined) return []
    return [
      {
        folderName: checkout.folderName,
        name: project.name,
        repoDir: location.folderPath,
        projectId: project.id
      }
    ]
  })
}

const messagingSection = (conversational: boolean): ReadonlyArray<string> =>
  conversational ? BOT_MESSAGING_SECTION : []

const followUpStep = (conversational: boolean): string =>
  conversational ? EVENT_FOLLOW_UP_STEP : WAIT_FOLLOW_UP_STEP

export const upgradeBotInstructions = (text: string, conversational: boolean): string => {
  const section = BOT_MESSAGING_SECTION.join("\n") + "\n"
  const steps = withCurrentDelegationSteps(text, conversational).replace(
    conversational ? WAIT_FOLLOW_UP_STEP : EVENT_FOLLOW_UP_STEP,
    followUpStep(conversational)
  )
  if (!conversational) return steps.replace(section, "")
  if (steps.includes(BOT_MESSAGING_SECTION[0]!)) return steps
  const repositories = steps.indexOf("## Repositories")
  return repositories === -1
    ? `${steps.trimEnd()}\n\n${section}`
    : steps.slice(0, repositories) + section + steps.slice(repositories)
}

const withCurrentDelegationSteps = (text: string, conversational: boolean): string => {
  const [worktreeStep, createStep, promptStep, waitStep, eventStep] = LEGACY_DELEGATION_STEPS
  return text
    .replace(LEGACY_MESSAGING_LINE, BOT_MESSAGING_SECTION[3]!)
    .replace(worktreeStep!, START_STEP)
    .replace(createStep!, "")
    .replace(promptStep!, "")
    .replace(waitStep!, followUpStep(conversational))
    .replace(eventStep!, followUpStep(conversational))
}

export const upgradeAllBotInstructions = async (
  services: CodevisorServerServices
): Promise<void> => {
  for (const bot of await run(services.db.listBots)) {
    const path = join(bot.rootPath, "AGENTS.md")
    try {
      const current = readFileSync(path, "utf8")
      const upgraded = replaceRepositories(
        upgradeBotInstructions(current, bot.conversational),
        await botRepositories(services, bot)
      )
      if (upgraded !== current) writeFileSync(path, upgraded)
    } catch {}
  }
}

export const syncBotRepositories = async (
  services: CodevisorServerServices,
  bot: Bot
): Promise<void> => {
  const path = join(bot.rootPath, "AGENTS.md")
  try {
    writeFileSync(
      path,
      replaceRepositories(readFileSync(path, "utf8"), await botRepositories(services, bot))
    )
  } catch {}
}

export const botInstructions = (
  name: string,
  conversational: boolean,
  repositories: ReadonlyArray<BotRepository>
): string =>
  [
    `# ${name}`,
    "",
    "You are a long-lived Codevisor bot that coordinates work across the repositories below.",
    "Plan the work, hand it to sub-agents, and follow up on their results. Don't change code",
    "yourself; read the folders below to understand the code and decide what to delegate.",
    "",
    ...messagingSection(conversational),
    ...repositoriesSection(repositories),
    "## Delegating work",
    "",
    "Give each task to a sub-agent in a workspace of its own with the Codevisor MCP's execute",
    "tool, on an isolated worktree of the repository it changes. Use the projectId above; this",
    "folder is not a project you can branch from.",
    "",
    START_STEP,
    followUpStep(conversational),
    "",
    "Workspaces your sub-agents work in, and any they create, are listed under this bot in the",
    "Codevisor sidebar.",
    ""
  ].join("\n")

export const writeInstructions = (
  slug: string,
  name: string,
  conversational: boolean,
  repositories: ReadonlyArray<BotRepository>
) => {
  writeFileSync(
    join(botPath(slug), "AGENTS.md"),
    botInstructions(name, conversational, repositories)
  )
}

export const renameInstructions = (rootPath: string, name: string): void => {
  const path = join(rootPath, "AGENTS.md")
  try {
    writeFileSync(path, readFileSync(path, "utf8").replace(/^# .*$/m, `# ${name}`))
  } catch {}
}
