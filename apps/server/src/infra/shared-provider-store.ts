import { createHash } from "node:crypto"

import type { CodevisorDatabaseService } from "@codevisor/db"
import type {
  SharedCredentialReference,
  SharedCredentialVault,
  SharedTokenBundle,
  ProviderOAuthHarness
} from "@codevisor/harness-manager"
import { latestSyncTimestamp, nextSyncTimestamp } from "@codevisor/sync"
import { Effect } from "effect"

import { field, isRecord } from "../unknown-values.js"
import type { SharedAccountStore } from "./shared-account-store.js"

export const PROVIDER_LOCAL = "local.shared-provider-accounts"
export const providerSlot = (harness: string, profile: string, provider: string) =>
  `provider:${JSON.stringify([harness, profile, provider])}`
export const providerDigest = (value: string) => createHash("sha256").update(value).digest("hex")

export const providerProfile = async (
  db: CodevisorDatabaseService,
  harness: ProviderOAuthHarness,
  id: string
): Promise<string> => {
  if (harness !== "opencode" || id === "default") return "default"
  const account = await Effect.runPromise(db.getHarnessAccount(id))
  if (!account || account.harnessId !== harness) throw new Error("OpenCode profile not found")
  return account.profileKind === "default" ? "default" : account.id
}

export interface SharedProviderRecord {
  readonly harnessId: ProviderOAuthHarness
  readonly profileId: string
  readonly providerId: string
  readonly subject: string
  readonly organizationId?: string
  readonly credential: SharedCredentialReference
}

export const isProviderHarness = (id: unknown): id is ProviderOAuthHarness =>
  id === "pi" || id === "opencode" || id === "grok-build"

const isProviderRecord = (value: unknown): value is SharedProviderRecord => {
  if (!isRecord(value)) return false
  const credentialId = field(value.credential, "id")
  const credentialKey = field(value.credential, "key")
  return (
    isProviderHarness(value.harnessId) &&
    typeof value.profileId === "string" &&
    typeof value.providerId === "string" &&
    typeof value.subject === "string" &&
    (value.organizationId === undefined || typeof value.organizationId === "string") &&
    typeof credentialId === "string" &&
    /^[\w-]{16,100}$/.test(credentialId) &&
    typeof credentialKey === "string" &&
    /^[\w-]{43}$/.test(credentialKey)
  )
}

export const providerRecord = (value: unknown): SharedProviderRecord | undefined =>
  isProviderRecord(value) ? value : undefined

export const makeSharedProviderStore = (options: {
  db: CodevisorDatabaseService
  store: SharedAccountStore
  vault: SharedCredentialVault
  serverId: string
}) => {
  const { db, store, vault, serverId } = options
  const localEntries = () => Effect.runPromise(db.getSyncEntries(PROVIDER_LOCAL))
  const local = async (key: string) =>
    (await localEntries()).find((entry) => entry.key === key && !entry.deleted)?.value
  const setLocal = async (key: string, value: unknown) => {
    const entries = await localEntries()
    if (JSON.stringify(entries.find((entry) => entry.key === key)?.value) === JSON.stringify(value))
      return
    await Effect.runPromise(
      db.mergeSyncEntries(PROVIDER_LOCAL, [
        {
          key,
          value,
          timestamp: nextSyncTimestamp(serverId, latestSyncTimestamp(entries), Date.now())
        }
      ])
    )
  }
  const get = async (slot: string) => {
    const entry = (await store.entries()).find(
      (candidate) => candidate.key === slot && !candidate.deleted
    )
    const record = providerRecord(entry?.value)
    return record && providerSlot(record.harnessId, record.profileId, record.providerId) === slot
      ? record
      : undefined
  }
  const records = async (harness: ProviderOAuthHarness, profile: string) => {
    const rows: SharedProviderRecord[] = []
    for (const entry of await store.entries()) {
      if (!entry.key.startsWith("provider:")) continue
      const row = await get(entry.key)
      if (row?.harnessId === harness && row.profileId === profile) rows.push(row)
    }
    return rows
  }
  const signedOut = async (slot: string) =>
    (await store.entries()).some((entry) => entry.key === slot && entry.deleted)
  const replace = async (
    slot: string,
    current: SharedProviderRecord | undefined,
    bundle: ProviderBundle,
    profile: string
  ) => {
    const credential = await vault.create(bundle)
    await store.writeProvider(slot, providerRecordFor(bundle, profile, credential))
    if (current) await vault.revoke(current.credential)
  }
  const adoptMachineLogin = async (
    slot: string,
    current: SharedProviderRecord | undefined,
    bundle: ProviderBundle,
    profile: string
  ) => {
    if (await signedOut(slot)) return
    if (current === undefined) return replace(slot, current, bundle, profile)
    if (sameSubject(current, bundle) && bundle.ownership === "external")
      await vault.publishExternal(current.credential, bundle)
  }
  const save = async (bundle: ProviderBundle, profile: string, explicit: boolean) => {
    const slot = providerSlot(bundle.harnessId, profile, bundle.providerId!)
    const current = await get(slot)
    if (!explicit) return adoptMachineLogin(slot, current, bundle, profile)

    await replace(slot, current, bundle, profile)
  }
  return {
    local,
    setLocal,
    localEntries,
    get,
    records,
    save,
    knownProviders: async (harness: ProviderOAuthHarness, profile: string): Promise<string[]> => {
      const ids = new Set<string>()
      for (const entry of await store.entries()) {
        const provider = slotProvider(entry.key, harness, profile)
        if (provider !== undefined) ids.add(provider)
      }
      return [...ids]
    },
    remove: async (harness: ProviderOAuthHarness, profile: string, provider: string) => {
      const slot = providerSlot(harness, profile, provider)
      const row = await get(slot)
      if (!row) return false

      await vault.revoke(row.credential)
      await store.writeProvider(slot, null, true)
      return true
    }
  }
}

export type SharedProviderStore = ReturnType<typeof makeSharedProviderStore>

type ProviderBundle = SharedTokenBundle & { harnessId: ProviderOAuthHarness }

const sameSubject = (row: SharedProviderRecord, bundle: SharedTokenBundle): boolean =>
  row.subject === bundle.subject && row.organizationId === bundle.organizationId

const providerRecordFor = (
  bundle: ProviderBundle,
  profile: string,
  credential: SharedCredentialReference
): SharedProviderRecord => ({
  harnessId: bundle.harnessId,
  profileId: profile,
  providerId: bundle.providerId!,
  subject: bundle.subject,
  credential,
  ...(bundle.organizationId ? { organizationId: bundle.organizationId } : {})
})

const slotProvider = (
  key: string,
  harness: ProviderOAuthHarness,
  profile: string
): string | undefined => {
  if (!key.startsWith("provider:")) return undefined
  try {
    const parts: unknown = JSON.parse(key.slice("provider:".length))
    if (!Array.isArray(parts) || parts.length !== 3) return undefined
    if (parts[0] !== harness || parts[1] !== profile || typeof parts[2] !== "string")
      return undefined
    return parts[2]
  } catch {
    return undefined
  }
}
