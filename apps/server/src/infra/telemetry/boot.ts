import { startServerAnalytics } from "../analytics/boot.js"
import { startServerDiagnostics } from "../diagnostics/boot.js"
import type { SettingsDatabase } from "./telemetry-settings.js"

export const startServerTelemetry = (options: {
  readonly db: SettingsDatabase
  readonly serverId: string
  readonly version: string | undefined
  readonly env: Readonly<Record<string, string | undefined>>
}): void => {
  startServerDiagnostics(options)
  startServerAnalytics(options)
}
