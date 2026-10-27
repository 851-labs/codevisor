import { toBase64Url } from "@codevisor/cloud-crypto"

import type { CloudEnv } from "./env.js"

export interface InboxTarget {
  readonly plugin: string
  readonly accountId: string
  readonly ingress: string
}

export const MAX_INBOXES_PER_USER = 1_000

const INBOX_ID_BYTES = 16

export const inboxUrl = (env: CloudEnv, inboxId: string): string => {
  if (env.HOOKS_BASE_URL) return `${env.HOOKS_BASE_URL}/i/${inboxId}`
  return `${env.PUBLIC_BASE_URL}/hooks/i/${inboxId}`
}

export const provisionInbox = async (
  db: D1Database,
  userId: string,
  target: InboxTarget
): Promise<string | undefined> => {
  const [, existing] = await db.batch<IdRow>([
    db
      .prepare(inboxSql.insertIfRoom)
      .bind(
        newInboxId(),
        userId,
        target.plugin,
        target.accountId,
        target.ingress,
        Date.now(),
        MAX_INBOXES_PER_USER
      ),
    db.prepare(inboxSql.byTarget).bind(userId, target.plugin, target.accountId, target.ingress)
  ])
  return existing?.results[0]?.id
}

export const inboxOwner = async (db: D1Database, inboxId: string): Promise<string | undefined> => {
  const row = await db.prepare(inboxSql.owner).bind(inboxId).first<OwnerRow>()
  return row?.user_id
}

export const ownsInbox = async (
  db: D1Database,
  userId: string,
  inboxId: string
): Promise<boolean> => (await inboxOwner(db, inboxId)) === userId

export const deleteInbox = async (
  db: D1Database,
  userId: string,
  inboxId: string
): Promise<boolean> => {
  const result = await db.prepare(inboxSql.delete).bind(inboxId, userId).run()
  return result.meta.changes > 0
}

const newInboxId = (): string => toBase64Url(crypto.getRandomValues(new Uint8Array(INBOX_ID_BYTES)))

interface IdRow {
  id: string
}

interface OwnerRow {
  user_id: string
}

const inboxSql = {
  insertIfRoom: `INSERT INTO inbox (id, user_id, plugin, account_id, ingress, created_at)
     SELECT ?1, ?2, ?3, ?4, ?5, ?6
     WHERE (SELECT COUNT(*) FROM inbox WHERE user_id = ?2) < ?7
     ON CONFLICT(user_id, plugin, account_id, ingress) DO NOTHING`,
  byTarget:
    "SELECT id FROM inbox WHERE user_id = ? AND plugin = ? AND account_id = ? AND ingress = ?",
  owner: "SELECT user_id FROM inbox WHERE id = ?",
  delete: "DELETE FROM inbox WHERE id = ? AND user_id = ?"
}
