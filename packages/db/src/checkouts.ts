import { randomUUID } from "node:crypto"

import { isoTimestamp } from "@codevisor/api"
import type Database from "better-sqlite3"

import { checkoutRows, type CheckoutRow } from "./checkout-rows.js"
import { canonicalUuid } from "./ids.js"
import { resolveSessionCwd, worktreeNameAt } from "./paths.js"
import { integer, rowReader, text } from "./row-reader.js"

export interface CheckoutPlace {
  readonly serverId: string
  readonly projectId: string
  readonly path: string
  readonly worktreeName?: string | undefined
}

export const ensureCheckout = (sqlite: Database.Database, place: CheckoutPlace): string => {
  const existing = checkoutAt(sqlite, place.serverId, place.path)
  if (existing !== undefined) return existing.id

  const id = randomUUID()
  const worktreeName = place.worktreeName ?? worktreeNameAt(place.projectId, place.path)
  sqlite
    .prepare(checkoutSql.insert)
    .run(
      id,
      place.serverId,
      canonicalUuid(place.projectId),
      worktreeId(sqlite, place, worktreeName),
      worktreeName ?? null,
      place.path,
      isoTimestamp()
    )
  return id
}

export const sessionCheckoutPlace = (
  serverId: string,
  projectId: string,
  folderPath: string | undefined,
  worktreeName: string | undefined
): CheckoutPlace | undefined => {
  const path = resolveSessionCwd(folderPath, projectId, worktreeName)
  if (path === undefined) return undefined
  return { serverId, projectId, path, worktreeName }
}

export const checkoutAt = (
  sqlite: Database.Database,
  serverId: string,
  path: string
): CheckoutRow | undefined =>
  checkoutRows.maybe(sqlite.prepare(checkoutSql.byPlace).get(serverId, path))

export const checkoutRow = (sqlite: Database.Database, id: string): CheckoutRow | undefined =>
  checkoutRows.maybe(sqlite.prepare(checkoutSql.byId).get(id))

export const listCheckoutRows = (sqlite: Database.Database): ReadonlyArray<CheckoutRow> =>
  checkoutRows.all(sqlite.prepare(checkoutSql.list).all())

export const sessionCheckoutId = (sqlite: Database.Database, sessionId: string): string | null =>
  checkoutIdRows.maybe(sqlite.prepare(checkoutSql.sessionCheckout).get(sessionId))?.checkout_id ??
  null

export const workspaceDefaultCheckoutId = (
  sqlite: Database.Database,
  workspaceId: string
): string | null =>
  checkoutIdRows.maybe(sqlite.prepare(checkoutSql.workspaceDefault).get(workspaceId))
    ?.checkout_id ?? null

export const paneCheckoutId = (
  sqlite: Database.Database,
  workspaceId: string,
  resourceKind: string | null | undefined,
  resourceId: string | null,
  requested: string | null | undefined
): string | null => {
  if (resourceKind === "session" && resourceId !== null)
    return sessionCheckoutId(sqlite, resourceId)
  if (requested != null) return canonicalUuid(requested)
  return workspaceDefaultCheckoutId(sqlite, workspaceId)
}

export const adoptDefaultCheckout = (
  sqlite: Database.Database,
  workspaceId: string,
  sessionId: string
): void => {
  sqlite.prepare(checkoutSql.adoptDefault).run(sessionId, workspaceId)
}

const worktreeId = (
  sqlite: Database.Database,
  place: CheckoutPlace,
  worktreeName: string | undefined
): string | null => {
  if (worktreeName === undefined) return null
  return (
    idRows.maybe(
      sqlite
        .prepare(checkoutSql.worktreeId)
        .get(canonicalUuid(place.projectId), place.serverId, worktreeName)
    )?.id ?? null
  )
}

export interface WorktreePlace {
  readonly id: string
  readonly serverId: string
  readonly name: string
  readonly path: string
}

export const retireCheckoutOf = (sqlite: Database.Database, worktree: WorktreePlace): void => {
  sqlite
    .prepare(checkoutSql.retire)
    .run(worktree.id, isoTimestamp(), worktree.serverId, worktree.path)
}

export const claimCheckoutFor = (sqlite: Database.Database, worktree: WorktreePlace): void => {
  const own = checkoutRows.maybe(sqlite.prepare(checkoutSql.retiredOf).get(worktree.id))
  if (own === undefined) {
    sqlite
      .prepare(checkoutSql.retireStranger)
      .run(isoTimestamp(), worktree.serverId, worktree.path, worktree.id)
    sqlite.prepare(checkoutSql.adopt).run(worktree.id, worktree.serverId, worktree.path)
    return
  }
  sqlite.prepare(checkoutSql.retireAt).run(isoTimestamp(), worktree.serverId, worktree.path)
  sqlite.prepare(checkoutSql.revive).run(worktree.path, worktree.name, own.id)
}

export const checkoutInUse = (sqlite: Database.Database, checkoutId: string): boolean =>
  inUseRows.one(sqlite.prepare(checkoutSql.inUse).get({ id: checkoutId })).in_use === 1

const inUseRows = rowReader({ in_use: integer })

const idRows = rowReader({ id: text })

const checkoutIdRows = rowReader({ checkout_id: text })

const checkoutSql = {
  inUse: `select (
      exists (select 1 from sessions where checkout_id = @id and is_archived = 0)
      or exists (
        select 1 from workspace_panes
          join workspaces on workspaces.id = workspace_panes.workspace_id
          where workspace_panes.checkout_id = @id and workspaces.is_archived = 0
      )
      or exists (
        select 1 from workspaces where default_checkout_id = @id and is_archived = 0
      )
    ) as in_use`,
  byId: "select * from checkouts where id = ?",
  byPlace: "select * from checkouts where server_id = ? and path = ? and retired_at is null",
  retire: `update checkouts set worktree_id = coalesce(worktree_id, ?), retired_at = ?
      where server_id = ? and path = ? and retired_at is null`,
  retiredOf: `select * from checkouts where worktree_id = ? and retired_at is not null
      order by retired_at desc, id limit 1`,
  retireStranger: `update checkouts set retired_at = ?
      where server_id = ? and path = ? and retired_at is null
        and worktree_id is not null and worktree_id <> ?`,
  adopt: `update checkouts set worktree_id = ?
      where server_id = ? and path = ? and retired_at is null and worktree_id is null`,
  retireAt: `update checkouts set retired_at = ?
      where server_id = ? and path = ? and retired_at is null`,
  revive: `update checkouts set path = ?, worktree_name = ?, retired_at = null,
        updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
      where id = ?`,
  list: "select * from checkouts order by created_at, id",
  insert: `insert into checkouts (
             id, server_id, project_id, worktree_id, worktree_name, path, created_at
           ) values (?, ?, ?, ?, ?, ?, ?)`,
  worktreeId: "select id from worktrees where project_id = ? and server_id = ? and name = ?",
  sessionCheckout: "select checkout_id from sessions where id = ? and checkout_id is not null",
  workspaceDefault:
    "select default_checkout_id as checkout_id from workspaces where id = ? and default_checkout_id is not null",
  adoptDefault: `update workspaces
      set default_checkout_id = coalesce(
        (select checkout_id from sessions where sessions.id = workspaces.main_session_id),
        (select checkout_id from sessions where sessions.id = ?)
      )
      where id = ? and default_checkout_id is null`
}
