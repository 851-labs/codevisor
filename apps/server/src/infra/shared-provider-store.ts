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
  const get = async (slot: string, shared = false) => {
    if (!shared) {
      const override = await local(slot)
      if (override === false) return undefined
      const record = providerRecord(override)
      if (record && providerSlot(record.harnessId, record.profileId, record.providerId) === slot)
        return record
    }
    const entry = (await store.entries()).find(
      (candidate) => candidate.key === slot && !candidate.deleted
    )
    const record = providerRecord(entry?.value)
    return record && providerSlot(record.harnessId, record.profileId, record.providerId) === slot
      ? record
      : undefined
  }
  const records = async (harness: ProviderOAuthHarness, profile: string, shared = false) => {
    const keys = new Set(
      [...(await store.entries()), ...(shared ? [] : await localEntries())]
        .filter((entry) => entry.key.startsWith("provider:"))
        .map((entry) => entry.key)
    )
    const rows: SharedProviderRecord[] = []
    for (const key of keys) {
      const row = await get(key, shared)
      if (row?.harnessId === harness && row.profileId === profile) rows.push(row)
    }
    return rows
  }
  const save = async (
    bundle: SharedTokenBundle & { harnessId: ProviderOAuthHarness },
    profile: string,
    explicit: boolean,
    shared: boolean
  ) => {
    const provider = bundle.providerId!
    const slot = providerSlot(bundle.harnessId, profile, provider)
    const global = await get(slot, true)
    const current = await get(slot)
    const same = (row: SharedProviderRecord | undefined) =>
      row?.subject === bundle.subject && row.organizationId === bundle.organizationId
    const destination = shared || !global ? global : same(global) ? global : current
    if (
      !explicit &&
      ((await store.entries()).some((entry) => entry.key === slot && entry.deleted) ||
        (await local(slot)) === false)
    )
      return
    if (!explicit && same(destination)) {
      if (bundle.ownership === "external")
        await vault.publishExternal(destination!.credential, bundle)
      return
    }
    if (explicit && !shared && same(global)) {
      await setLocal(slot, null)
    }
    const credential = await vault.create(bundle)
    const record: SharedProviderRecord = {
      harnessId: bundle.harnessId,
      profileId: profile,
      providerId: provider,
      subject: bundle.subject,
      credential,
      ...(bundle.organizationId ? { organizationId: bundle.organizationId } : {})
    }
    if (shared || !global || same(global)) {
      await store.writeProvider(slot, record)
      if (!shared) await setLocal(slot, null)
    } else await setLocal(slot, record)
    if (
      destination &&
      (shared || !global || same(global) || destination.credential.id !== global.credential.id)
    )
      await vault.revoke(destination.credential)
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
      for (const entry of [...(await store.entries()), ...(await localEntries())]) {
        if (!entry.key.startsWith("provider:")) continue
        try {
          const parts: unknown = JSON.parse(entry.key.slice("provider:".length))
          if (
            Array.isArray(parts) &&
            parts.length === 3 &&
            parts[0] === harness &&
            parts[1] === profile &&
            typeof parts[2] === "string"
          )
            ids.add(parts[2])
        } catch {}
      }
      return [...ids]
    },
    remove: async (
      harness: ProviderOAuthHarness,
      profile: string,
      provider: string,
      shared = false
    ) => {
      const slot = providerSlot(harness, profile, provider)
      const row = await get(slot, shared)
      if (!row) {
        if (!shared) await setLocal(slot, false)
        return false
      }
      if (shared) {
        await vault.revoke(row.credential)
        await store.writeProvider(slot, null, true)
      } else {
        const global = await get(slot, true)
        if (global?.credential.id !== row.credential.id) await vault.revoke(row.credential)
        await setLocal(slot, false)
      }
      return true
    }
  }
}

export type SharedProviderStore = ReturnType<typeof makeSharedProviderStore>
