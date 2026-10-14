import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"

import type { ServerUpdateChannel } from "./release-source.js"

export const APP_UPDATE_CHANNEL_FILE = "app-update-channel"
export const APP_UPDATE_FEED_FILE = "app-update-feed"
export const APP_UPDATE_STATUS_FILE = "app-update-status.json"

export const APP_UPDATE_STATUS_TTL_MS = 30 * 60 * 1000

export type AppUpdateApplyState = {
  readonly progress?: number | undefined
  readonly state: "installing" | "failed"
  readonly message?: string | undefined
  readonly targetVersion?: string | undefined
  readonly targetBuildNumber?: number | undefined
  readonly at: string
}

export const channelFromSyncedValue = (value: unknown): ServerUpdateChannel | undefined =>
  value === "alpha" || value === "stable" ? value : undefined

export const readMachineUpdateChannel = (dataDir: string): ServerUpdateChannel | undefined => {
  const path = join(dataDir, APP_UPDATE_CHANNEL_FILE)
  try {
    if (!existsSync(path)) return undefined
    const value = readFileSync(path, "utf8").trim()
    if (value.length === 0) return undefined
    return value === "alpha" ? "alpha" : "stable"
  } catch {
    return undefined
  }
}

export const readMachineUpdateFeedURL = (dataDir: string): string | undefined => {
  const path = join(dataDir, APP_UPDATE_FEED_FILE)
  let value: string
  try {
    if (!existsSync(path)) return undefined
    value = readFileSync(path, "utf8").trim()
  } catch {
    return undefined
  }
  try {
    const url = new URL(value)
    return url.protocol === "http:" || url.protocol === "https:" ? value : undefined
  } catch {
    return undefined
  }
}

export const readAppUpdateApplyState = (
  dataDir: string,
  now: () => number = Date.now
): AppUpdateApplyState | undefined => {
  const path = join(dataDir, APP_UPDATE_STATUS_FILE)
  let parsed: unknown
  try {
    if (!existsSync(path)) return undefined
    parsed = JSON.parse(readFileSync(path, "utf8"))
  } catch {
    return undefined
  }
  if (typeof parsed !== "object" || parsed === null) return undefined
  const value = parsed as {
    readonly progress?: unknown
    readonly state?: unknown
    readonly message?: unknown
    readonly targetVersion?: unknown
    readonly targetBuildNumber?: unknown
    readonly at?: unknown
  }
  if (value.state !== "installing" && value.state !== "failed") return undefined
  if (typeof value.at !== "string") return undefined
  const reportedAt = Date.parse(value.at)
  if (!Number.isFinite(reportedAt) || now() - reportedAt > APP_UPDATE_STATUS_TTL_MS) {
    return undefined
  }
  return {
    progress:
      value.state === "installing" &&
      typeof value.progress === "number" &&
      Number.isFinite(value.progress)
        ? Math.min(1, Math.max(0, value.progress))
        : undefined,
    state: value.state,
    message: typeof value.message === "string" ? value.message : undefined,
    targetVersion: typeof value.targetVersion === "string" ? value.targetVersion : undefined,
    targetBuildNumber:
      typeof value.targetBuildNumber === "number" &&
      Number.isSafeInteger(value.targetBuildNumber) &&
      value.targetBuildNumber > 0
        ? value.targetBuildNumber
        : undefined,
    at: value.at
  }
}
