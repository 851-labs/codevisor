import { toBase64Url } from "@codevisor/cloud-crypto"

import type { CloudEnv } from "./env.js"

export interface InboxTarget {
  readonly plugin: string
  readonly accountId: string
  readonly ingress: string
}

export const MAX_INBOXES_PER_USER = 1_000

const INBOX_ID_BYTES = 16

export const INBOXES_OFF =
  "Webhook inboxes are turned off on this Codevisor Cloud: HOOKS_BASE_URL isn't set"

export const hooksBaseUrl = (env: CloudEnv): string | undefined => env.HOOKS_BASE_URL || undefined

export const inboxUrl = (hooksBase: string, inboxId: string): string => `${hooksBase}/i/${inboxId}`

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

export interface RoutedInbox {
  readonly id: string
  readonly userId: string
}

export const routeInbox = async (
  db: D1Database,
  inboxId: string,
  route: string,
  routeKey: string
): Promise<void> => {
  await db.prepare(inboxSql.route).bind(inboxId, route, routeKey, Date.now()).run()
}

export const routedInboxes = async (
  db: D1Database,
  route: string,
  routeKey: string
): Promise<ReadonlyArray<RoutedInbox>> => {
  const rows = await db.prepare(inboxSql.routed).bind(route, routeKey).all<RoutedRow>()
  return rows.results.map((row) => ({ id: row.id, userId: row.user_id }))
}

const newInboxId = (): string => toBase64Url(crypto.getRandomValues(new Uint8Array(INBOX_ID_BYTES)))

interface IdRow {
  id: string
}

interface OwnerRow {
  user_id: string
}

interface RoutedRow {
  id: string
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
  delete: "DELETE FROM inbox WHERE id = ? AND user_id = ?",
  route: `INSERT INTO inbox_route (inbox_id, route, route_key, created_at) VALUES (?, ?, ?, ?)
     ON CONFLICT(inbox_id, route) DO UPDATE SET route_key = excluded.route_key`,
  routed: `SELECT inbox.id, inbox.user_id FROM inbox_route JOIN inbox ON inbox.id = inbox_route.inbox_id
     WHERE inbox_route.route = ? AND inbox_route.route_key = ? ORDER BY inbox.id`
}
