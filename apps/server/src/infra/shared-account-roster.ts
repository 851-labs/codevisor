import type { HarnessAccount } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { SharedCredentialVault, SharedOAuthHarness } from "@codevisor/harness-manager"
import { Effect } from "effect"

import type { SharedAccountCredentials } from "./shared-account-credentials.js"
import { publicAccount, type LocalAccountRows } from "./shared-account-local-rows.js"
import type { SharedAccountLocalState } from "./shared-account-local-state.js"
import { sharedHarness, type SharedAccountStore } from "./shared-account-store.js"

export interface SharedAccountRosterDeps {
  readonly db: CodevisorDatabaseService
  readonly store: SharedAccountStore
  readonly vault: SharedCredentialVault
  readonly localState: SharedAccountLocalState
  readonly localRows: LocalAccountRows
  readonly credentials: SharedAccountCredentials
  readonly reconcile: () => Promise<void>
}

export const makeSharedAccountRoster = (deps: SharedAccountRosterDeps) => {
  const { db, store, localState, localRows, credentials } = deps

  const storedAccounts = async (
    harnessId: SharedOAuthHarness
  ): Promise<ReadonlyArray<HarnessAccount>> => {
    const sharedIds = new Set((await store.accounts()).map((account) => account.id))
    const rows: HarnessAccount[] = []
    for (const row of await run(db.listHarnessAccounts(harnessId))) {
      const shared = row.id.startsWith("shared-")
      if (shared && !sharedIds.has(row.id)) continue
      if (!shared && localState.isCapturingLogin(row.id)) continue
      if (!shared && (await localState.hasAlias(row.id))) continue

      rows.push(publicAccount(row))
    }
    return rows
  }

  const accounts = async (
    harnessId: string,
    shared = false
  ): Promise<ReadonlyArray<HarnessAccount> | undefined> => {
    if (!sharedHarness(harnessId)) return undefined

    await deps.reconcile()
    const selected = await store.selected(harnessId)

    const rows: HarnessAccount[] = []
    for (const account of await store.accounts()) {
      if (account.harnessId !== harnessId) continue

      const value = await credentials.probe(account.id, shared)
      if (value) rows.push({ ...value, isActive: account.id === selected })
    }
    if (shared) return rows

    for (const row of await storedAccounts(harnessId))
      if (!row.id.startsWith("shared-")) rows.push(row)
    return rows
  }

  const activate = async (harnessId: string, id: string): Promise<boolean> => {
    const account = await credentials.resolve(id)
    if (!account) return false
    if (account.harnessId !== harnessId) throw new Error("Account belongs to another harness")
    if (!account.credential) throw new Error("Sign in to this account first")

    await deps.vault.token(account.credential)
    await store.select(harnessId, account.id)
    await localRows.applySelection(harnessId)
    await credentials.probe(account.id)
    return true
  }

  return {
    accounts,
    storedAccounts: async (harnessId: string) => {
      if (!sharedHarness(harnessId)) return undefined
      return storedAccounts(harnessId)
    },
    activate
  }
}

const run = Effect.runPromise
