import { createHash } from "node:crypto"
import { arch, platform, release } from "node:os"

import {
  isDevelopmentServer,
  syncedTelemetrySettings,
  type SettingsDatabase
} from "../telemetry/telemetry-settings.js"
import { postHogSender } from "./posthog-transport.js"
import { installServerAnalytics, makeServerAnalytics } from "./server-analytics.js"

export const startServerAnalytics = (options: {
  readonly db: SettingsDatabase
  readonly serverId: string
  readonly version: string | undefined
  readonly env: Readonly<Record<string, string | undefined>>
}): void => {
  if (isDevelopmentServer(options.env) && options.env.CODEVISOR_ENABLE_ANALYTICS !== "1") return

  installServerAnalytics(
    makeServerAnalytics({
      settings: syncedTelemetrySettings(options.db, "shareAnalytics"),
      send: postHogSender({
        projectToken: options.env.CODEVISOR_POSTHOG_PROJECT_TOKEN ?? codevisorPostHogProjectToken,
        host: options.env.CODEVISOR_POSTHOG_HOST ?? codevisorPostHogHost
      }),
      distinctId: anonymousMachineId(options.serverId),
      properties: serverProperties(options.version, options.env)
    })
  )
}

const codevisorPostHogProjectToken = "phc_Bjioc2MPX8qEqgnZdfuboi4Uu268kCE3pJSkMfSJtDwi"
const codevisorPostHogHost = "https://us.i.posthog.com"
const machineIdLength = 32

const anonymousMachineId = (serverId: string): string =>
  createHash("sha256")
    .update(`codevisor-server:${serverId}`)
    .digest("hex")
    .slice(0, machineIdLength)

const serverProperties = (
  version: string | undefined,
  env: Readonly<Record<string, string | undefined>>
): Readonly<Record<string, string>> => ({
  platform: "server",
  os: platform(),
  os_version: release(),
  arch: arch(),
  app_version: version ?? "unknown",
  release_channel: isDevelopmentServer(env) ? "development" : "release"
})
