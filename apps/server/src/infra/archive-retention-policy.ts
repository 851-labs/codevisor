import { ARCHIVE_RETENTION_SINCE_SETTING, type CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"

export const ARCHIVE_RETENTION_SETTING_KEY = "archivedChatRetention"

export interface ArchiveRetentionPolicy {
  readonly hasExpired: (archivedAt: string | undefined) => boolean
}

type PolicyDatabase = Pick<
  CodevisorDatabaseService,
  "getSyncEntries" | "getMachineSetting" | "setMachineSetting"
>

export const archiveRetentionPolicy = async (
  db: PolicyDatabase,
  now: number
): Promise<ArchiveRetentionPolicy | undefined> => {
  const days = retentionDays(await syncedRetention(db))
  if (days === undefined) return undefined

  const since = await retentionSince(db, now)
  const deadline = now - days * dayMs
  return { hasExpired: (archivedAt) => expiresBy(archivedAt, since, deadline) }
}

const settingsNamespace = "settings"

const dayMs = 86_400_000

const defaultRetentionDays = 30

const daysByRetention: Readonly<Record<string, number>> = {
  "7-days": 7,
  "30-days": 30,
  "90-days": 90
}

const retentionDays = (value: unknown): number | undefined => {
  if (value === "never") return undefined
  if (typeof value !== "string") return defaultRetentionDays
  return daysByRetention[value] ?? defaultRetentionDays
}

const syncedRetention = async (db: PolicyDatabase): Promise<unknown> => {
  const entries = await Effect.runPromise(db.getSyncEntries(settingsNamespace))
  return entries.find((entry) => entry.key === ARCHIVE_RETENTION_SETTING_KEY && !entry.deleted)
    ?.value
}

const retentionSince = async (db: PolicyDatabase, now: number): Promise<number> => {
  const stored = Date.parse(
    (await Effect.runPromise(db.getMachineSetting(ARCHIVE_RETENTION_SINCE_SETTING))) ?? ""
  )
  if (Number.isFinite(stored)) return stored

  await Effect.runPromise(
    db.setMachineSetting(ARCHIVE_RETENTION_SINCE_SETTING, new Date(now).toISOString())
  )
  return now
}

const expiresBy = (archivedAt: string | undefined, since: number, deadline: number): boolean => {
  if (archivedAt === undefined) return false

  const clockStart = Math.max(Date.parse(archivedAt), since)
  return clockStart <= deadline
}
