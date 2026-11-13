import type { Bot, SessionSummary } from "@codevisor/api"
import {
  removeUnreferencedAttachments,
  type AttachmentStore,
  type CodevisorDatabaseService
} from "@codevisor/db"
import { Effect } from "effect"

import {
  archiveRetentionPolicy,
  type ArchiveRetentionPolicy
} from "./infra/archive-retention-policy.js"

export interface ArchiveRetentionDeps {
  readonly db: CodevisorDatabaseService
  readonly attachments: AttachmentStore
  readonly deleteChat: (chat: SessionSummary) => Promise<void>
  readonly removeBot: (bot: Bot) => Promise<void>
  readonly forgetUnrestorableSnapshots: () => Promise<void>
}

export interface ArchiveRetentionSchedule {
  readonly firstSweepMs: number
  readonly intervalMs: number
}

export const archiveRetentionSchedule: ArchiveRetentionSchedule = {
  firstSweepMs: 60_000,
  intervalMs: 3_600_000
}

export const startArchiveRetention = (
  deps: ArchiveRetentionDeps,
  schedule: ArchiveRetentionSchedule = archiveRetentionSchedule
): (() => void) => {
  const sweep = singleFlight(() => sweepArchives(deps, Date.now()))
  const first = setTimeout(sweep, schedule.firstSweepMs)
  const repeat = setInterval(sweep, schedule.intervalMs)
  first.unref()
  repeat.unref()
  return () => {
    clearTimeout(first)
    clearInterval(repeat)
  }
}

export const sweepArchives = async (deps: ArchiveRetentionDeps, now: number): Promise<void> => {
  await expireByRetention(deps, now)
  await deps.forgetUnrestorableSnapshots()
  await removeUnreferencedAttachments(deps.db, deps.attachments)
  await run(deps.db.releaseFreeSpace)
}

const expireByRetention = async (deps: ArchiveRetentionDeps, now: number): Promise<void> => {
  const policy = await archiveRetentionPolicy(deps.db, now)
  if (policy === undefined) return

  await removeExpiredBots(deps, policy)
  await deleteExpiredChats(deps, policy)
  await deleteUnusedFiles(deps, policy)
}

const removeExpiredBots = async (
  deps: ArchiveRetentionDeps,
  policy: ArchiveRetentionPolicy
): Promise<void> => {
  const expired = (await run(deps.db.listBots)).filter((bot) => isExpiredBot(bot, policy))
  for (const bot of expired) await deps.removeBot(bot).catch(reportFailure)
}

const deleteExpiredChats = async (
  deps: ArchiveRetentionDeps,
  policy: ArchiveRetentionPolicy
): Promise<void> => {
  const botHomes = new Set((await run(deps.db.listBots)).map((bot) => bot.projectId))
  const expired = (await run(deps.db.listSessions)).filter(
    (chat) => !botHomes.has(chat.projectId) && isExpiredChat(chat, policy)
  )
  for (const chat of expired) await deps.deleteChat(chat).catch(reportFailure)
}

const deleteUnusedFiles = async (
  deps: ArchiveRetentionDeps,
  policy: ArchiveRetentionPolicy
): Promise<void> => {
  const expired = (await run(deps.db.listUnusedFiles)).filter((file) =>
    policy.hasExpired(file.createdAt)
  )
  if (expired.length === 0) return

  await run(deps.db.deleteFiles(expired.map((file) => file.id)))
}

const isExpiredBot = (bot: Bot, policy: ArchiveRetentionPolicy): boolean =>
  bot.isArchived && policy.hasExpired(bot.archivedAt)

const isExpiredChat = (chat: SessionSummary, policy: ArchiveRetentionPolicy): boolean =>
  chat.isArchived === true && policy.hasExpired(chat.archivedAt)

const singleFlight = (work: () => Promise<void>): (() => void) => {
  let running: Promise<void> | undefined
  return () => {
    running ??= work()
      .catch(reportFailure)
      .finally(() => {
        running = undefined
      })
  }
}

const reportFailure = (cause: unknown): void => {
  console.error(`Archive cleanup failed: ${String(cause)}`)
}

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)
