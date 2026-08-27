import { isoTimestamp } from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { attempt } from "./errors.js"
import { harnessAccountFromRow } from "./row-mappers.js"
import type { HarnessAccountRecord, HarnessAccountRow } from "./rows.js"
import type { CodevisorDatabaseService } from "./service.js"
import type { ServiceContext } from "./service-context.js"

export const makeHarnessService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "setHarnessEnabled"
  | "applyHarnessSettings"
  | "listHarnessAccounts"
  | "getHarnessAccount"
  | "saveHarnessAccount"
  | "updateHarnessAccountAuth"
  | "setActiveHarnessAccount"
  | "removeHarnessAccount"
  | "bindSessionHarnessAccount"
  | "rebindHarnessAccountSessions"
> => {
  const { sqlite, getSession } = context

  const harnessAccountRows = (harnessId: string): ReadonlyArray<HarnessAccountRow> =>
    sqlite
      .prepare(
        `select a.*,
                case when s.account_id = a.id then 1 else 0 end as is_active
         from harness_accounts a
         left join harness_account_selection s on s.harness_id = a.harness_id
         where a.harness_id = ? and a.removed_at is null
         order by is_active desc, a.created_at asc`
      )
      .all(harnessId) as ReadonlyArray<HarnessAccountRow>

  const requiredHarnessAccount = (accountId: string): HarnessAccountRecord => {
    const row = sqlite
      .prepare(
        `select a.*,
                case when s.account_id = a.id then 1 else 0 end as is_active
         from harness_accounts a
         left join harness_account_selection s on s.harness_id = a.harness_id
         where a.id = ? and a.removed_at is null`
      )
      .get(accountId) as HarnessAccountRow | undefined
    if (row === undefined) throw new Error(`Harness account not found: ${accountId}`)
    return harnessAccountFromRow(row)
  }

  return {
    setHarnessEnabled: (harnessId, enabled) =>
      attempt("setHarnessEnabled", () => {
        sqlite
          .prepare(
            `insert into harness_settings (harness_id, enabled) values (?, ?)
             on conflict(harness_id) do update set enabled = excluded.enabled`
          )
          .run(harnessId, enabled ? 1 : 0)
      }),
    applyHarnessSettings: (harnesses) =>
      attempt("applyHarnessSettings", () => {
        const disabled = new Set(
          sqlite
            .prepare("select harness_id from harness_settings where enabled = 0")
            .all()
            .map((row) => (row as { readonly harness_id: string }).harness_id)
        )
        return harnesses.map((harness) => ({ ...harness, enabled: !disabled.has(harness.id) }))
      }),
    listHarnessAccounts: (harnessId) =>
      attempt("listHarnessAccounts", () =>
        harnessAccountRows(harnessId).map(harnessAccountFromRow)
      ),
    getHarnessAccount: (accountId) =>
      attempt("getHarnessAccount", () => {
        const row = sqlite
          .prepare(
            `select a.*,
                    case when s.account_id = a.id then 1 else 0 end as is_active
             from harness_accounts a
             left join harness_account_selection s on s.harness_id = a.harness_id
             where a.id = ? and a.removed_at is null`
          )
          .get(accountId) as HarnessAccountRow | undefined
        return row === undefined ? undefined : harnessAccountFromRow(row)
      }),
    saveHarnessAccount: (request) =>
      attempt("saveHarnessAccount", () => {
        const now = isoTimestamp()
        const existing =
          request.profileKind === "default"
            ? (sqlite
                .prepare(
                  "select id from harness_accounts where harness_id = ? and profile_kind = 'default' and removed_at is null"
                )
                .get(request.harnessId) as { readonly id: string } | undefined)
            : request.profileKey === undefined
              ? undefined
              : (sqlite
                  .prepare(
                    "select id from harness_accounts where harness_id = ? and profile_key = ? and removed_at is null"
                  )
                  .get(request.harnessId, request.profileKey) as
                  | { readonly id: string }
                  | undefined)
        const id = existing?.id ?? request.id ?? randomUUID()
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
        const selected = sqlite
          .prepare("select account_id from harness_account_selection where harness_id = ?")
          .get(request.harnessId) as { readonly account_id: string } | undefined
        if (selected === undefined) {
          sqlite
            .prepare("insert into harness_account_selection (harness_id, account_id) values (?, ?)")
            .run(request.harnessId, id)
        }
        return requiredHarnessAccount(id)
      }),
    updateHarnessAccountAuth: (accountId, request) =>
      attempt("updateHarnessAccountAuth", () => {
        const current = requiredHarnessAccount(accountId)
        sqlite
          .prepare(
            `update harness_accounts set
               label = ?, email = ?, organization_id = ?, auth_method = ?, auth_state = ?,
               can_login = ?, can_logout = ?, last_checked_at = ?, detail = ?, updated_at = ?
             where id = ? and removed_at is null`
          )
          .run(
            request.label ?? current.label,
            request.email === undefined ? (current.email ?? null) : request.email,
            request.organizationId === undefined
              ? (current.organizationId ?? null)
              : request.organizationId,
            request.authMethod === undefined ? (current.authMethod ?? null) : request.authMethod,
            request.authState,
            (request.canLogin ?? current.canLogin) ? 1 : 0,
            (request.canLogout ?? current.canLogout) ? 1 : 0,
            request.lastCheckedAt ?? isoTimestamp(),
            request.detail === undefined ? (current.detail ?? null) : request.detail,
            isoTimestamp(),
            accountId
          )
        return requiredHarnessAccount(accountId)
      }),
    setActiveHarnessAccount: (harnessId, accountId) =>
      attempt("setActiveHarnessAccount", () => {
        const account = requiredHarnessAccount(accountId)
        if (account.harnessId !== harnessId) throw new Error("Account belongs to another harness")
        sqlite
          .prepare(
            `insert into harness_account_selection (harness_id, account_id) values (?, ?)
             on conflict(harness_id) do update set account_id = excluded.account_id`
          )
          .run(harnessId, accountId)
      }),
    removeHarnessAccount: (accountId) =>
      attempt("removeHarnessAccount", () => {
        const account = requiredHarnessAccount(accountId)
        if (account.profileKind === "default") {
          throw new Error("The default harness profile cannot be removed")
        }
        const inUse = sqlite
          .prepare("select id from sessions where harness_account_id = ? limit 1")
          .get(accountId)
        if (inUse !== undefined) throw new Error("Account is used by an existing session")
        sqlite.prepare("delete from harness_account_selection where account_id = ?").run(accountId)
        sqlite
          .prepare("update harness_accounts set removed_at = ?, updated_at = ? where id = ?")
          .run(isoTimestamp(), isoTimestamp(), accountId)
      }),
    bindSessionHarnessAccount: (sessionId, accountId) =>
      attempt("bindSessionHarnessAccount", () => {
        requiredHarnessAccount(accountId)
        sqlite
          .prepare("update sessions set harness_account_id = ? where id = ?")
          .run(accountId, sessionId)
        return getSession(sessionId)
      }),
    rebindHarnessAccountSessions: (fromAccountId, toAccountId) =>
      attempt("rebindHarnessAccountSessions", () => {
        requiredHarnessAccount(toAccountId)
        return sqlite
          .prepare("update sessions set harness_account_id = ? where harness_account_id = ?")
          .run(toAccountId, fromAccountId).changes
      })
  }
}
