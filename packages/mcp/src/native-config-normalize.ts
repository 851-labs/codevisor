import type { McpTransport } from "@codevisor/api"

import { isNonArrayRecord } from "./mcp-guards.js"

export interface NormalizedNativeServer {
  readonly transport: McpTransport
  readonly url?: string | undefined
  readonly command?: string | undefined
  readonly args: ReadonlyArray<string>
  readonly env: Readonly<Record<string, string>>
  readonly headers: Readonly<Record<string, string>>
  readonly enabled?: boolean | undefined
  readonly raw: Readonly<Record<string, unknown>>
}

const asString = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

const asStringArray = (value: unknown): ReadonlyArray<string> =>
  Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : []

const asStringRecord = (value: unknown): Readonly<Record<string, string>> => {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return {}
  const record: Record<string, string> = {}
  for (const [key, item] of Object.entries(value)) {
    if (typeof item === "string") record[key] = item
  }
  return record
}

const remote = (
  raw: Record<string, unknown>,
  url: string,
  headers: Readonly<Record<string, string>>,
  enabled?: boolean
): NormalizedNativeServer => ({
  args: [],
  enabled,
  env: {},
  headers,
  raw,
  transport: "http",
  url
})

const stdio = (
  raw: Record<string, unknown>,
  command: string,
  args: ReadonlyArray<string>,
  env: Readonly<Record<string, string>>,
  enabled?: boolean
): NormalizedNativeServer => ({
  args,
  command,
  enabled,
  env,
  headers: {},
  raw,
  transport: "stdio",
  url: undefined
})

export const normalizeNativeServer = (
  harnessId: string,
  raw: unknown
): NormalizedNativeServer | undefined => {
  if (!isNonArrayRecord(raw)) return undefined
  switch (harnessId) {
    case "opencode":
      return normalizeOpenCodeServer(raw)
    case "codex":
      return normalizeCodexServer(raw)
    case "goose":
      return normalizeGooseServer(raw)
    case "cline":
      return normalizeClineServer(raw)
    default:
      return normalizeStandardServer(raw)
  }
}

const normalizeOpenCodeServer = (
  entry: Record<string, unknown>
): NormalizedNativeServer | undefined => {
  const enabled = entry["enabled"] !== false
  const url = asString(entry["url"])
  if (url !== undefined) return remote(entry, url, asStringRecord(entry["headers"]), enabled)
  const commandParts = asStringArray(entry["command"])
  const [command, ...args] = commandParts
  if (command === undefined) return undefined
  return stdio(entry, command, args, asStringRecord(entry["environment"]), enabled)
}

const normalizeCodexServer = (
  entry: Record<string, unknown>
): NormalizedNativeServer | undefined => {
  const url = asString(entry["url"])
  if (url !== undefined) return remote(entry, url, asStringRecord(entry["http_headers"]))
  const command = asString(entry["command"])
  if (command === undefined) return undefined
  return stdio(entry, command, asStringArray(entry["args"]), asStringRecord(entry["env"]))
}

const normalizeGooseServer = (
  entry: Record<string, unknown>
): NormalizedNativeServer | undefined => {
  const enabled = entry["enabled"] !== false
  const url = asString(entry["uri"])
  if (url !== undefined) return remote(entry, url, asStringRecord(entry["headers"]), enabled)
  const command = asString(entry["cmd"])
  if (command === undefined) return undefined
  return stdio(entry, command, asStringArray(entry["args"]), asStringRecord(entry["envs"]), enabled)
}

const normalizeClineServer = (
  entry: Record<string, unknown>
): NormalizedNativeServer | undefined => {
  const enabled = entry["disabled"] !== true
  const url = asString(entry["url"])
  if (url !== undefined) return remote(entry, url, asStringRecord(entry["headers"]), enabled)
  const command = asString(entry["command"])
  if (command === undefined) return undefined
  return stdio(entry, command, asStringArray(entry["args"]), asStringRecord(entry["env"]), enabled)
}

const normalizeStandardServer = (
  entry: Record<string, unknown>
): NormalizedNativeServer | undefined => {
  const url = asString(entry["url"])
  if (url !== undefined) return remote(entry, url, asStringRecord(entry["headers"]))
  const command = asString(entry["command"])
  if (command === undefined) return undefined
  return stdio(entry, command, asStringArray(entry["args"]), asStringRecord(entry["env"]))
}

export const extractServerIdentity = (raw: Record<string, unknown>): string => {
  for (const key of ["url", "uri", "serverUrl"]) {
    const value = raw[key]
    if (typeof value === "string" && value.length > 0) return normalizeUrlIdentity(value)
  }
  const command = nativeIdentityCommand(raw)
  const rawArgs = nativeIdentityArguments(raw)
  return command === undefined
    ? nativeArrayCommandIdentity(raw)
    : nativeCommandIdentity(command, rawArgs)
}

const nativeIdentityCommand = (raw: Record<string, unknown>): string | undefined =>
  typeof raw["command"] === "string"
    ? raw["command"]
    : typeof raw["cmd"] === "string"
      ? raw["cmd"]
      : undefined

const nativeIdentityArguments = (raw: Record<string, unknown>): ReadonlyArray<string> =>
  Array.isArray(raw["args"])
    ? raw["args"].filter((item): item is string => typeof item === "string")
    : Array.isArray(raw["command"])
      ? raw["command"].slice(1).filter((item): item is string => typeof item === "string")
      : []

const nativeArrayCommandIdentity = (raw: Record<string, unknown>): string => {
  if (Array.isArray(raw["command"])) {
    const parts = raw["command"].filter((item): item is string => typeof item === "string")
    const [first, ...rest] = parts
    if (first === undefined) return ""
    return packageIdentity(first, rest) ?? parts.join(" ")
  }
  return ""
}

const nativeCommandIdentity = (command: string, rawArgs: ReadonlyArray<string>): string => {
  const packaged = packageIdentity(command, rawArgs)
  if (packaged !== undefined) return packaged
  if (rawArgs.length > 0) return `${command} ${rawArgs.join(" ")}`
  return command
}

const packageIdentity = (command: string, args: ReadonlyArray<string>): string | undefined => {
  if (command !== "npx" && command !== "bunx") return undefined
  const yIndex = args.indexOf("-y")
  const pkg = args[yIndex >= 0 ? yIndex + 1 : 0]
  if (pkg !== undefined && !pkg.startsWith("-")) return pkg
  return undefined
}

const normalizeUrlIdentity = (identity: string): string => {
  if (!identity.startsWith("http://") && !identity.startsWith("https://")) return identity
  try {
    const url = new URL(identity)
    const pathname = url.pathname.replace(/\/+$/, "")
    return `${url.protocol}//${url.host}${pathname}${url.search}`
  } catch {
    return identity
  }
}
