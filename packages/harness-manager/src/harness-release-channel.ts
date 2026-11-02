import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

import type { UpdateCheckSpec } from "@codevisor/agent-runtime"

type ReleaseChannelCheck = Extract<UpdateCheckSpec, { readonly kind: "releaseChannel" }>

export const configuredReleaseChannel = (
  check: ReleaseChannelCheck,
  home: string | undefined
): string => {
  const setting = settingValue(join(homeDirectory(home), check.channelSetting.file), check)
  return isChannelName(setting) ? setting : check.defaultChannel
}

const settingValue = (path: string, check: ReleaseChannelCheck): unknown => {
  try {
    const settings: unknown = JSON.parse(readFileSync(path, "utf8"))
    return isRecord(settings) ? settings[check.channelSetting.key] : undefined
  } catch {
    return undefined
  }
}

const homeDirectory = (home: string | undefined): string => {
  if (home !== undefined) return home

  const envHome = process.env.HOME
  return envHome === undefined || envHome === "" ? homedir() : envHome
}

const isChannelName = (value: unknown): value is string =>
  typeof value === "string" && /^[a-z][a-z0-9-]*$/.test(value)

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)
