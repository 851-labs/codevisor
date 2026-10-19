import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { botPath } from "@codevisor/db"

import { run, type CodevisorServerServices } from "../server-context.js"
import type { BotCheckout } from "./bot-create.js"

const BOT_MESSAGING_SECTION: ReadonlyArray<string> = [
  "## Talking to the user",
  "",
  "The user chats with you like iMessage and only sees the messages you send with",
  "`codevisor.messages.send` through the Codevisor MCP. Nothing else you write reaches them, not",
  "even your final reply. Read the `codevisor-messages` skill before your first reply.",
  ""
]

const WAIT_FOLLOW_UP_STEP = "4. `sessions.wait` or `sessions.get` to follow up"

const LEGACY_CREATE_STEP = "2. `sessions.create({ projectId, worktreeName, title })`"

const createStep = (harnessId: string): string =>
  `2. \`sessions.create({ projectId, worktreeName, harnessId: "${harnessId}", title })\``

const EVENT_FOLLOW_UP_STEP =
  "4. End your turn. When the agent finishes, Codevisor sends you a `<codevisor-event>` with its result"

const messagingSection = (conversational: boolean): ReadonlyArray<string> =>
  conversational ? BOT_MESSAGING_SECTION : []

const followUpStep = (conversational: boolean): string =>
  conversational ? EVENT_FOLLOW_UP_STEP : WAIT_FOLLOW_UP_STEP

export const upgradeBotInstructions = (
  text: string,
  harnessId: string,
  conversational: boolean
): string => {
  const section = BOT_MESSAGING_SECTION.join("\n") + "\n"
  const steps = text
    .replace(
      conversational ? WAIT_FOLLOW_UP_STEP : EVENT_FOLLOW_UP_STEP,
      followUpStep(conversational)
    )
    .replace(LEGACY_CREATE_STEP, createStep(harnessId))
  if (!conversational) return steps.replace(section, "")
  if (steps.includes(BOT_MESSAGING_SECTION[0]!)) return steps
  const repositories = steps.indexOf("## Repositories")
  return repositories === -1
    ? `${steps.trimEnd()}\n\n${section}`
    : steps.slice(0, repositories) + section + steps.slice(repositories)
}

export const upgradeAllBotInstructions = async (
  services: CodevisorServerServices
): Promise<void> => {
  for (const bot of await run(services.db.listBots)) {
    const path = join(bot.rootPath, "AGENTS.md")
    try {
      const current = readFileSync(path, "utf8")
      const upgraded = upgradeBotInstructions(current, bot.harnessId, bot.conversational)
      if (upgraded !== current) writeFileSync(path, upgraded)
    } catch {}
  }
}

export const botInstructions = (
  name: string,
  harnessId: string,
  conversational: boolean,
  checkouts: ReadonlyArray<BotCheckout>
): string =>
  [
    `# ${name}`,
    "",
    "You are a long-lived Codevisor bot that coordinates work across the repositories below.",
    "Plan the work, hand it to sub-agents, and follow up on their results. Don't change code",
    "yourself; read the folders below to understand the code and decide what to delegate.",
    "",
    ...messagingSection(conversational),
    "## Repositories",
    "",
    ...checkouts.map(
      (checkout) =>
        `- \`${checkout.folderName}/\`: ${checkout.source.project.name} ` +
        `(from \`${checkout.source.repoDir}\`, projectId \`${checkout.source.project.id}\`)`
    ),
    "",
    "## Delegating work",
    "",
    "Give each task to a sub-agent in a workspace of its own with the Codevisor MCP, on an",
    "isolated worktree of the repository it changes. Use the projectId above; this folder is",
    "not a project you can branch from.",
    "",
    "1. `worktrees.create({ projectId })`",
    createStep(harnessId),
    "3. `sessions.prompt({ sessionId, text })`",
    followUpStep(conversational),
    "",
    "Workspaces your sub-agents work in, and any they create, are listed under this bot in the",
    "Codevisor sidebar.",
    ""
  ].join("\n")

export const writeInstructions = (
  slug: string,
  name: string,
  harnessId: string,
  conversational: boolean,
  checkouts: ReadonlyArray<BotCheckout>
) => {
  writeFileSync(
    join(botPath(slug), "AGENTS.md"),
    botInstructions(name, harnessId, conversational, checkouts)
  )
}

export const renameInstructions = (rootPath: string, name: string): void => {
  const path = join(rootPath, "AGENTS.md")
  try {
    writeFileSync(path, readFileSync(path, "utf8").replace(/^# .*$/m, `# ${name}`))
  } catch {}
}
