import type { CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"

import { enabledFeatureFlags } from "../feature-flags.js"
import { syncedUpdateChannel } from "../release-channel.js"

export interface TelemetrySettings {
  readonly enabled: () => Promise<boolean>
  readonly enabledFlags: () => Promise<ReadonlySet<string>>
  readonly updateChannel: () => Promise<string>
}

export interface TelemetryContext {
  readonly updateChannel: string
  readonly flags: ReadonlyArray<string>
}

export type TelemetryChoice = "shareAnalytics" | "shareCrashReports"

export type SettingsDatabase = Pick<CodevisorDatabaseService, "getSyncEntries">

export const flagTagPrefix = "flag_"

export const syncedTelemetrySettings = (
  db: SettingsDatabase,
  choice: TelemetryChoice
): TelemetrySettings => ({
  enabled: () => syncedChoiceEnabled(db, choice),
  enabledFlags: () => enabledFeatureFlags(db),
  updateChannel: async () => {
    const channel = await syncedUpdateChannel(db)
    return typeof channel === "string" ? channel : "stable"
  }
})

export const syncedChoiceEnabled = async (
  db: SettingsDatabase,
  choice: TelemetryChoice
): Promise<boolean> =>
  (await Effect.runPromise(db.getSyncEntries("settings"))).some(
    (entry) => entry.key === choice && entry.value === true && entry.deleted !== true
  )

export const telemetryContext = async (settings: TelemetrySettings): Promise<TelemetryContext> => ({
  updateChannel: await settings.updateChannel(),
  flags: [...(await settings.enabledFlags())].toSorted()
})

export const isDevelopmentServer = (env: Readonly<Record<string, string | undefined>>): boolean =>
  env.CODEVISOR_DEV_INSTANCE_ID !== undefined || env.HERDMAN_DEV_INSTANCE_ID !== undefined
