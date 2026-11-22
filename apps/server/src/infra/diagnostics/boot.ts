import { arch, platform, release } from "node:os"

import type { CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"

import { enabledFeatureFlags } from "../feature-flags.js"
import { syncedUpdateChannel } from "../release-channel.js"
import type { DiagnosticEnvironment } from "./sentry-event.js"
import { parseSentryDsn, sentryEnvelopeSender } from "./sentry-transport.js"
import {
  installServerDiagnostics,
  makeServerDiagnostics,
  type DiagnosticsSettings
} from "./server-diagnostics.js"

type SettingsDatabase = Pick<CodevisorDatabaseService, "getSyncEntries">

export const crashReportsSettingKey = "shareCrashReports"

export const startServerDiagnostics = (options: {
  readonly db: SettingsDatabase
  readonly version: string | undefined
  readonly env: Readonly<Record<string, string | undefined>>
}): void => {
  const dsn = parseSentryDsn(options.env.CODEVISOR_SENTRY_DSN ?? codevisorServerSentryDsn)
  if (dsn === undefined || !reportsFrom(options.env)) return

  installServerDiagnostics(
    makeServerDiagnostics({
      settings: databaseSettings(options.db),
      environment: serverEnvironment(options.version, options.env),
      send: sentryEnvelopeSender(dsn)
    })
  )
}

export const crashReportsEnabled = async (db: SettingsDatabase): Promise<boolean> =>
  (await Effect.runPromise(db.getSyncEntries("settings"))).some(
    (entry) =>
      entry.key === crashReportsSettingKey && entry.value === true && entry.deleted !== true
  )

const codevisorServerSentryDsn =
  "https://c293cd825b1545aa663f20c21a7b9d66@o4506921350070272.ingest.us.sentry.io/4511781287231488"

const reportsFrom = (env: Readonly<Record<string, string | undefined>>): boolean =>
  !isDevelopment(env) || env.CODEVISOR_ENABLE_DIAGNOSTICS === "1"

const isDevelopment = (env: Readonly<Record<string, string | undefined>>): boolean =>
  env.CODEVISOR_DEV_INSTANCE_ID !== undefined || env.HERDMAN_DEV_INSTANCE_ID !== undefined

const databaseSettings = (db: SettingsDatabase): DiagnosticsSettings => ({
  enabled: () => crashReportsEnabled(db),
  enabledFlags: () => enabledFeatureFlags(db),
  updateChannel: async () => {
    const channel = await syncedUpdateChannel(db)
    return typeof channel === "string" ? channel : "stable"
  }
})

const serverEnvironment = (
  version: string | undefined,
  env: Readonly<Record<string, string | undefined>>
): DiagnosticEnvironment => ({
  release: `codevisor-server@${version ?? "unknown"}`,
  environment: isDevelopment(env) ? "development" : "production",
  tags: {
    runtime: "server",
    server_version: version ?? "unknown",
    os: platform(),
    os_version: release(),
    arch: arch(),
    node_version: process.versions.node
  }
})
