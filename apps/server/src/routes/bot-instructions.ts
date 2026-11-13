import { readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import type { Bot } from "@codevisor/api"
import { botPath } from "@codevisor/db"

import { run, type CodevisorServerServices } from "../server-context.js"
import { notesOutsideBlock } from "./bot-instructions-notes.js"
import {
  BLOCK_BEGIN,
  BLOCK_END,
  NOTES_HEADING,
  codevisorBlock,
  type BotInstructionsSubject,
  type BotRepository
} from "./bot-instructions-text.js"

export type { BotRepository } from "./bot-instructions-text.js"

export const writeInstructions = (slug: string, subject: BotInstructionsSubject): void => {
  writeFileSync(instructionsPath(botPath(slug)), withNotes(codevisorBlock(subject), []))
}

export const syncBotInstructions = async (
  services: CodevisorServerServices,
  bot: Bot
): Promise<boolean> => {
  const path = instructionsPath(bot.rootPath)
  const current = readIfPresent(path)
  if (current === undefined) return false

  const subject = await instructionsSubject(services, bot)
  const updated = instructionsWithBlock(current, subject)
  if (updated === current) return false

  writeFileSync(path, updated)
  return true
}

export const copyBotNotes = (
  services: CodevisorServerServices,
  source: Bot,
  target: Bot
): Promise<void> => writeBotNotes(services, target, botNotes(source))

export const botNotes = (bot: Bot): string | undefined =>
  readIfPresent(instructionsPath(bot.rootPath))

export const writeBotNotes = async (
  services: CodevisorServerServices,
  bot: Bot,
  notes: string | undefined
): Promise<void> => {
  if (notes === undefined) return

  const subject = await instructionsSubject(services, bot)
  writeFileSync(instructionsPath(bot.rootPath), instructionsWithBlock(notes, subject))
}

export const syncAllBotInstructions = async (
  services: CodevisorServerServices
): Promise<ReadonlyArray<Bot>> => {
  const changed: Array<Bot> = []
  for (const bot of await run(services.db.listBots)) {
    const synced = await syncBotInstructions(services, bot).catch(() => false)
    if (synced) changed.push(bot)
  }
  return changed
}

export const instructionsWithBlock = (text: string, subject: BotInstructionsSubject): string => {
  const block = codevisorBlock(subject)
  const span = blockSpan(text)
  if (span !== undefined) return text.slice(0, span.start) + block + text.slice(span.end)

  return withNotes(block, notesOutsideBlock(text, block))
}

interface BlockSpan {
  readonly start: number
  readonly end: number
}

const blockSpan = (text: string): BlockSpan | undefined => {
  const start = text.indexOf(BLOCK_BEGIN)
  const end = text.indexOf(BLOCK_END, start)
  if (start === -1 || end === -1) return undefined
  return { start, end: end + BLOCK_END.length }
}

const withNotes = (block: string, notes: ReadonlyArray<string>): string =>
  [block, NOTES_HEADING, ...notes].join("\n\n") + "\n"

const instructionsSubject = async (
  services: CodevisorServerServices,
  bot: Bot
): Promise<BotInstructionsSubject> => ({
  name: bot.name,
  repositories: await botRepositories(services, bot)
})

const botRepositories = async (
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

const instructionsPath = (rootPath: string): string => join(rootPath, "AGENTS.md")

const readIfPresent = (path: string): string | undefined => {
  try {
    return readFileSync(path, "utf8")
  } catch {
    return undefined
  }
}
