import { FEATURE_FLAGS_NAMESPACE, type FeatureFlagState } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { SyncEntryRecord, SyncMergeResult } from "@codevisor/sync"
import { Effect } from "effect"

import { openSyncStamps } from "./sync-ledger.js"

interface FeatureFlagDefinition {
  readonly id: string
  readonly title: string
  readonly description: string
}

export const featureFlagCatalog: ReadonlyArray<FeatureFlagDefinition> = [
  {
    id: "developerMode",
    title: "Developer Mode",
    description:
      "Adds a Developer section to the command palette with tools such as the debug overlay."
  },
  {
    id: "gmailPlugin",
    title: "Gmail Plugin",
    description:
      "Shows Gmail in Browse Plugins on all your devices. In testing: only @851.sh Google accounts can sign in."
  }
]

type FlagDatabase = Pick<CodevisorDatabaseService, "getSyncEntries">

export const featureFlagStates = async (
  db: FlagDatabase
): Promise<ReadonlyArray<FeatureFlagState>> => {
  const enabled = await enabledFeatureFlags(db)
  return featureFlagCatalog.map((flag) => ({ ...flag, enabled: enabled.has(flag.id) }))
}

export const enabledFeatureFlags = async (db: FlagDatabase): Promise<ReadonlySet<string>> => {
  const entries = await Effect.runPromise(db.getSyncEntries(FEATURE_FLAGS_NAMESPACE))
  return new Set(entries.filter(isEnabled).map((entry) => entry.key))
}

export const setFeatureFlag = async (
  db: Pick<CodevisorDatabaseService, "getSyncEntries" | "mergeSyncEntries">,
  serverId: string,
  id: string,
  enabled: boolean
): Promise<SyncMergeResult> => {
  const entries = await Effect.runPromise(db.getSyncEntries(FEATURE_FLAGS_NAMESPACE))
  const stamps = openSyncStamps({ serverId }, entries)
  return Effect.runPromise(
    db.mergeSyncEntries(FEATURE_FLAGS_NAMESPACE, [stamps.entry(id, enabled)])
  )
}

const isEnabled = (entry: SyncEntryRecord): boolean =>
  entry.value === true && entry.deleted !== true
