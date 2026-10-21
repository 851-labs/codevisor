import type { CodevisorDatabaseService } from "@codevisor/db"
import {
  sharedOAuthIdentity,
  type SharedCredentialReference,
  type SharedOAuthHarness,
  type SharedTokenBundle
} from "@codevisor/harness-manager"
import { latestSyncTimestamp, nextSyncTimestamp, type SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"

import { field, isRecord, stringField } from "../unknown-values.js"

export const SHARED_ACCOUNTS_NAMESPACE = "harness-shared-accounts"
export const SHARED_ACCOUNT_OVERRIDES = "local.harness-account-overrides"

export interface SharedHarnessAccount {
  readonly id: string
  readonly harnessId: SharedOAuthHarness
  readonly label: string
  readonly subject?: string
  readonly email?: string
  readonly organizationId?: string
  readonly createdAt: number
  readonly credential?: SharedCredentialReference
  readonly sourceMachineId?: string
  readonly sourceExpiresAt?: number
}

export const sharedAccountLabel = (bundle: SharedTokenBundle, chosen?: string): string => {
  if (chosen && chosen !== "New Account" && !/^Account [0-9a-f]{6}$/.test(chosen)) return chosen
  if (bundle.email) return bundle.email
  if (bundle.harnessId === "antigravity" && bundle.authMethod === "apiKey")
    return `Gemini API key ••••${bundle.accessToken.slice(-4)}`
  return (
    ({ codex: "ChatGPT", "muse-code": "Meta", antigravity: "Google" } as Record<string, string>)[
      bundle.harnessId
    ] ?? "Claude"
  )
}

export const sharedAccountFor = (
  bundle: SharedTokenBundle,
  credential: SharedCredentialReference,
  previous: SharedHarnessAccount | undefined,
  serverId: string,
  label?: string
): SharedHarnessAccount => {
  const harnessId = bundle.harnessId
  if (harnessId === "mcp") throw new Error("An MCP sign-in is not a harness account")
  return {
    id: sharedOAuthIdentity(bundle),
    harnessId,
    label: previous?.label ?? sharedAccountLabel(bundle, label),
    subject: bundle.subject,
    ...(bundle.email ? { email: bundle.email } : {}),
    ...(bundle.organizationId ? { organizationId: bundle.organizationId } : {}),
    createdAt: previous?.createdAt ?? Date.now(),
    credential,
    ...(bundle.ownership === "external"
      ? { sourceMachineId: serverId, sourceExpiresAt: bundle.expiresAt }
      : {})
  }
}

export const sharedHarness = (id: string): id is SharedOAuthHarness =>
  id === "claude-code" || id === "codex" || id === "muse-code" || id === "antigravity"
const isSharedAccount = (value: unknown): value is SharedHarnessAccount => {
  if (!isRecord(value)) return false
  const { id, harnessId, label, createdAt, credential } = value
  if (
    typeof id !== "string" ||
    !/^shared-[a-zA-Z0-9-]+$/.test(id) ||
    typeof harnessId !== "string" ||
    !sharedHarness(harnessId) ||
    typeof label !== "string" ||
    !Number.isFinite(createdAt)
  )
    return false
  const credentialId = field(credential, "id")
  const credentialKey = field(credential, "key")
  if (
    credential !== undefined &&
    (typeof credentialId !== "string" ||
      !/^[a-zA-Z0-9_-]{16,100}$/.test(credentialId) ||
      typeof credentialKey !== "string" ||
      !/^[a-zA-Z0-9_-]{43}$/.test(credentialKey))
  )
    return false
  return [value.subject, value.email, value.organizationId, value.sourceMachineId].every(
    (optional) => optional === undefined || typeof optional === "string"
  )
}

export const sharedAccountValue = (value: unknown): SharedHarnessAccount | undefined =>
  isSharedAccount(value) ? value : undefined

export const harnessesSignedInBy = (
  entries: ReadonlyArray<Pick<SyncEntryRecord, "key" | "value">>
): ReadonlyArray<string> => {
  const harnesses = new Set<string>()
  for (const { key, value } of entries) {
    if (key.startsWith("provider:")) {
      try {
        const parsed: unknown = JSON.parse(key.slice("provider:".length))
        const harness: unknown = Array.isArray(parsed) ? parsed[0] : undefined
        if (typeof harness === "string") harnesses.add(harness)
      } catch {}
    } else if (key.startsWith("selected:")) {
      harnesses.add(key.slice("selected:".length))
    } else if (key.startsWith("shared-")) {
      const harness = sharedAccountValue(value)?.harnessId
      if (harness !== undefined) harnesses.add(harness)
    }
  }
  return [...harnesses]
}

export const makeSharedAccountStore = (db: CodevisorDatabaseService, serverId: string) => {
  const listeners = new Set<(entries: ReadonlyArray<SyncEntryRecord>) => void>()
  const entries = () => Effect.runPromise(db.getSyncEntries(SHARED_ACCOUNTS_NAMESPACE))
  const write = async (namespace: string, key: string, value: unknown, deleted = false) => {
    const previous = await Effect.runPromise(db.getSyncEntries(namespace))
    const current = previous.find((entry) => entry.key === key)
    if (
      current &&
      (current.deleted === true) === deleted &&
      JSON.stringify(current.value) === JSON.stringify(value)
    )
      return
    const entry = {
      key,
      value,
      deleted,
      timestamp: nextSyncTimestamp(serverId, latestSyncTimestamp(previous), Date.now())
    }
    await Effect.runPromise(db.mergeSyncEntries(namespace, [entry]))
    if (namespace === SHARED_ACCOUNTS_NAMESPACE) for (const listener of listeners) listener([entry])
  }
  const accounts = async (): Promise<SharedHarnessAccount[]> =>
    (await entries()).flatMap((entry) => {
      if (entry.deleted === true || !entry.key.startsWith("shared-")) return []
      const value = sharedAccountValue(entry.value)
      return value && value.id === entry.key ? [value] : []
    })
  return {
    accounts,
    entries,
    writeProvider: (key: string, value: unknown, deleted = false) =>
      write(SHARED_ACCOUNTS_NAMESPACE, key, value, deleted),
    overridden: async (harnessId: string) => {
      const available = await accounts()
      return (await Effect.runPromise(db.getSyncEntries(SHARED_ACCOUNT_OVERRIDES))).some(
        (entry) =>
          entry.key === harnessId &&
          entry.deleted !== true &&
          available.some((account) => account.id === entry.value && account.credential)
      )
    },
    get: async (id: string) => (await accounts()).find((account) => account.id === id),
    save: (account: SharedHarnessAccount) => write(SHARED_ACCOUNTS_NAMESPACE, account.id, account),
    remove: (id: string) => write(SHARED_ACCOUNTS_NAMESPACE, id, null, true),
    selected: async (harnessId: string, machine: boolean): Promise<string | undefined> => {
      const available = (await accounts())
        .filter((account) => account.harnessId === harnessId && account.credential !== undefined)
        .toSorted((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id))
      if (machine) {
        const overrides = await Effect.runPromise(db.getSyncEntries(SHARED_ACCOUNT_OVERRIDES))
        const override = overrides.find((entry) => entry.key === harnessId)
        if (
          override?.deleted !== true &&
          typeof override?.value === "string" &&
          available.some((account) => account.id === override.value)
        )
          return override.value
      }
      const selected = (await entries()).find((entry) => entry.key === `selected:${harnessId}`)
      const selectedId = stringField(selected?.value, "id")
      if (
        selected?.deleted !== true &&
        field(selected?.value, "automatic") !== true &&
        available.some((account) => account.id === selectedId)
      )
        return selectedId
      return available[0]?.id
    },
    select: (harnessId: string, id: string, machine: boolean) =>
      write(
        machine ? SHARED_ACCOUNT_OVERRIDES : SHARED_ACCOUNTS_NAMESPACE,
        machine ? harnessId : `selected:${harnessId}`,
        machine ? id : { id, automatic: false }
      ),
    inherit: (harnessId: string) => write(SHARED_ACCOUNT_OVERRIDES, harnessId, null, true),
    subscribe: (listener: (entries: ReadonlyArray<SyncEntryRecord>) => void) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    }
  }
}

export type SharedAccountStore = ReturnType<typeof makeSharedAccountStore>
