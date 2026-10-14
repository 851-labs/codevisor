import { randomUUID } from "node:crypto"

import { isoTimestamp } from "@codevisor/api"

import type { SaveHarnessAccountRequest } from "./rows.js"
import type { ServiceContext } from "./service-context.js"

type Sqlite = ServiceContext["sqlite"]

type ExistingAccount = { readonly id: string } | undefined

const findExistingAccount = (
  sqlite: Sqlite,
  request: SaveHarnessAccountRequest
): ExistingAccount => {
  if (request.profileKind === "default") {
    return sqlite
      .prepare(
        "select id from harness_accounts where harness_id = ? and profile_kind = 'default' and removed_at is null"
      )
      .get(request.harnessId) as ExistingAccount
  }
  if (request.profileKey === undefined) return undefined
  return sqlite
    .prepare(
      "select id from harness_accounts where harness_id = ? and profile_key = ? and removed_at is null"
    )
    .get(request.harnessId, request.profileKey) as ExistingAccount
}

const upsertAccount = (
  sqlite: Sqlite,
  request: SaveHarnessAccountRequest,
  id: string,
  now: string
): void => {
  sqlite
    .prepare(
      `insert into harness_accounts (
               id, harness_id, profile_kind, profile_key, label, email, organization_id,
               auth_method, auth_state, can_login, can_logout, last_checked_at, detail,
               created_at, updated_at, removed_at
             ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, null)
             on conflict(id) do update set
               label = excluded.label,
               email = excluded.email,
               organization_id = excluded.organization_id,
               auth_method = excluded.auth_method,
               auth_state = excluded.auth_state,
               can_login = excluded.can_login,
               can_logout = excluded.can_logout,
               last_checked_at = excluded.last_checked_at,
               detail = excluded.detail,
               updated_at = excluded.updated_at,
               removed_at = null`
    )
    .run(
      id,
      request.harnessId,
      request.profileKind,
      request.profileKey ?? null,
      request.label,
      request.email ?? null,
      request.organizationId ?? null,
      request.authMethod ?? null,
      request.authState,
      request.canLogin ? 1 : 0,
      request.canLogout ? 1 : 0,
      request.lastCheckedAt ?? null,
      request.detail ?? null,
      now,
      now
    )
}

const selectFirstAccount = (
  sqlite: Sqlite,
  request: SaveHarnessAccountRequest,
  id: string
): void => {
  const selected = sqlite
    .prepare("select account_id from harness_account_selection where harness_id = ?")
    .get(request.harnessId) as { readonly account_id: string } | undefined
  if (selected === undefined) {
    sqlite
      .prepare("insert into harness_account_selection (harness_id, account_id) values (?, ?)")
      .run(request.harnessId, id)
  }
}

export const saveHarnessAccountId = (
  sqlite: Sqlite,
  request: SaveHarnessAccountRequest
): string => {
  const now = isoTimestamp()
  const existing = findExistingAccount(sqlite, request)
  const id = existing?.id ?? request.id ?? randomUUID()
  upsertAccount(sqlite, request, id, now)
  selectFirstAccount(sqlite, request, id)
  return id
}
