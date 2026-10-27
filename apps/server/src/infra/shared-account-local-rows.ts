import type { HarnessAccount } from "@codevisor/api"
import type {
  CodevisorDatabaseService,
  HarnessAccountRecord,
  SaveHarnessAccountRequest
} from "@codevisor/db"
import type { SharedTokenBundle } from "@codevisor/harness-manager"
import { Effect } from "effect"

import type { SharedAccountLocalState } from "./shared-account-local-state.js"
import type { SharedAccountStore, SharedHarnessAccount } from "./shared-account-store.js"

export interface LocalAccountRowsDeps {
  readonly db: CodevisorDatabaseService
  readonly store: SharedAccountStore
  readonly localState: SharedAccountLocalState
}

export const publicAccount = (record: HarnessAccountRecord): HarnessAccount => {
  const { profileKey: _key, createdAt: _created, updatedAt: _updated, ...account } = record
  return account
}

export type SelectionListener = (harnessId: string, accountId: string) => void

export const makeLocalAccountRows = ({ db, store, localState }: LocalAccountRowsDeps) => {
  const listeners = new Set<SelectionListener>()

  const save = async (account: SharedHarnessAccount, adopted?: SharedTokenBundle) => {
    const existing = await run(db.getHarnessAccount(account.id))
    const live = adopted !== undefined && adopted.expiresAt > Date.now() + liveGrantMarginMs
    return run(db.saveHarnessAccount(localRow(account, existing, live, adopted)))
  }

  const applySelection = async (harnessId: string) => {
    const selected = await store.selected(harnessId, true)
    if (!selected) return

    const rows = await run(db.listHarnessAccounts(harnessId))
    if (selectionIsSettled(rows, selected)) return

    await run(db.setActiveHarnessAccount(harnessId, selected))
    for (const previous of rows.filter((row) => replacedBySelection(row, selected, harnessId))) {
      if (harnessId === "codex" && (await localState.hasAlias(previous.id))) continue
      await run(db.rebindHarnessAccountSessions(previous.id, selected))
    }
    for (const listener of listeners) listener(harnessId, selected)
  }

  const subscribeSelections = (listener: SelectionListener) => {
    listeners.add(listener)
    return () => {
      listeners.delete(listener)
    }
  }

  return { save, applySelection, subscribeSelections }
}

export type LocalAccountRows = ReturnType<typeof makeLocalAccountRows>

const run = Effect.runPromise

const liveGrantMarginMs = 30_000

const localRow = (
  account: SharedHarnessAccount,
  existing: HarnessAccountRecord | undefined,
  live: boolean,
  adopted: SharedTokenBundle | undefined
): SaveHarnessAccountRequest => ({
  id: account.id,
  harnessId: account.harnessId,
  profileKind: "managed",
  profileKey: account.id,
  label: account.label,
  ...(account.email ? { email: account.email } : {}),
  ...(account.organizationId ? { organizationId: account.organizationId } : {}),
  authMethod: existing?.authMethod ?? adopted?.authMethod ?? "oauth",
  authState: existing?.authState ?? (live ? "authenticated" : "checking"),
  canLogin: true,
  canLogout: existing?.canLogout ?? account.credential !== undefined,
  ...(existing?.detail ? { detail: existing.detail } : {})
})

const selectionIsSettled = (rows: ReadonlyArray<HarnessAccountRecord>, selected: string): boolean =>
  !rows.some((row) => row.id === selected) ||
  rows.some((row) => row.id === selected && row.isActive)

const replacedBySelection = (
  row: HarnessAccountRecord,
  selected: string,
  harnessId: string
): boolean =>
  row.id !== selected && (harnessId === "claude-code" || row.authState !== "authenticated")
