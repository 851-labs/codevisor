import { arch, platform, release } from "node:os"

import {
  isDevelopmentServer,
  syncedTelemetrySettings,
  type SettingsDatabase
} from "../telemetry/telemetry-settings.js"
import type { DiagnosticEnvironment } from "./sentry-event.js"
import { parseSentryDsn, sentryEnvelopeSender } from "./sentry-transport.js"
import { installServerDiagnostics, makeServerDiagnostics } from "./server-diagnostics.js"

export const startServerDiagnostics = (options: {
  readonly db: SettingsDatabase
  readonly version: string | undefined
  readonly env: Readonly<Record<string, string | undefined>>
}): void => {
  const dsn = parseSentryDsn(options.env.CODEVISOR_SENTRY_DSN ?? codevisorServerSentryDsn)
  if (dsn === undefined || !reportsFrom(options.env)) return

  installServerDiagnostics(
    makeServerDiagnostics({
      settings: syncedTelemetrySettings(options.db, "shareCrashReports"),
      environment: serverEnvironment(options.version, options.env),
      send: sentryEnvelopeSender(dsn)
    })
  )
}

const codevisorServerSentryDsn =
  "https://c293cd825b1545aa663f20c21a7b9d66@o4506921350070272.ingest.us.sentry.io/4511781287231488"

const reportsFrom = (env: Readonly<Record<string, string | undefined>>): boolean =>
  !isDevelopmentServer(env) || env.CODEVISOR_ENABLE_DIAGNOSTICS === "1"

const serverEnvironment = (
  version: string | undefined,
  env: Readonly<Record<string, string | undefined>>
): DiagnosticEnvironment => ({
  release: `codevisor-server@${version ?? "unknown"}`,
  environment: isDevelopmentServer(env) ? "development" : "production",
  tags: {
    runtime: "server",
    server_version: version ?? "unknown",
    os: platform(),
    os_version: release(),
    arch: arch(),
    node_version: process.versions.node
  }
})
