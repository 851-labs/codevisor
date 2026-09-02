import type { McpTransport } from "@codevisor/api"

/// One native server entry translated out of a harness dialect. Secret values
/// (env/headers) stay server-side; API rows expose only their names.
export interface NormalizedNativeServer {
  readonly transport: McpTransport
  readonly url?: string | undefined
  readonly command?: string | undefined
  readonly args: ReadonlyArray<string>
  readonly env: Readonly<Record<string, string>>
  readonly headers: Readonly<Record<string, string>>
  /// Present only for dialects with a real per-server enable flag
  /// (opencode `enabled`, cline `disabled`, goose `enabled`).
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

/// Translate one raw server entry from a harness's native dialect into the
/// normalized shape. Returns undefined for entries with neither a URL nor a
/// command (unrecognizable — skipped, not fatal). Dialects are the reverse of
/// add-mcp's outbound transformConfig functions.
export const normalizeNativeServer = (
  harnessId: string,
  raw: unknown
): NormalizedNativeServer | undefined => {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return undefined
  const entry = raw as Record<string, unknown>
  switch (harnessId) {
    case "opencode": {
      const enabled = entry["enabled"] !== false
      const url = asString(entry["url"])
      if (url !== undefined) return remote(entry, url, asStringRecord(entry["headers"]), enabled)
      const commandParts = asStringArray(entry["command"])
      const [command, ...args] = commandParts
      if (command === undefined) return undefined
      return stdio(entry, command, args, asStringRecord(entry["environment"]), enabled)
    }
    case "codex": {
      const url = asString(entry["url"])
      if (url !== undefined) return remote(entry, url, asStringRecord(entry["http_headers"]))
      const command = asString(entry["command"])
      if (command === undefined) return undefined
      return stdio(entry, command, asStringArray(entry["args"]), asStringRecord(entry["env"]))
    }
    case "goose": {
      const enabled = entry["enabled"] !== false
      const url = asString(entry["uri"])
      if (url !== undefined) return remote(entry, url, asStringRecord(entry["headers"]), enabled)
      const command = asString(entry["cmd"])
      if (command === undefined) return undefined
      return stdio(
        entry,
        command,
        asStringArray(entry["args"]),
        asStringRecord(entry["envs"]),
        enabled
      )
    }
    case "cline": {
      const enabled = entry["disabled"] !== true
      const url = asString(entry["url"])
      if (url !== undefined) return remote(entry, url, asStringRecord(entry["headers"]), enabled)
      const command = asString(entry["command"])
      if (command === undefined) return undefined
      return stdio(
        entry,
        command,
        asStringArray(entry["args"]),
        asStringRecord(entry["env"]),
        enabled
      )
    }
    default: {
      // Standard spec-aligned shape: claude-code, gemini, github-copilot-cli,
      // and project .mcp.json files.
      const url = asString(entry["url"])
      if (url !== undefined) return remote(entry, url, asStringRecord(entry["headers"]))
      const command = asString(entry["command"])
      if (command === undefined) return undefined
      return stdio(entry, command, asStringArray(entry["args"]), asStringRecord(entry["env"]))
    }
  }
}

/// Extract a server's cross-harness identity (URL, package name, or command
/// line) from any dialect. Ported from add-mcp reader.ts.
export const extractServerIdentity = (raw: Record<string, unknown>): string => {
  for (const key of ["url", "uri", "serverUrl"]) {
    const value = raw[key]
    if (typeof value === "string" && value.length > 0) return normalizeUrlIdentity(value)
  }
  const command =
    typeof raw["command"] === "string"
      ? raw["command"]
      : typeof raw["cmd"] === "string"
        ? raw["cmd"]
        : undefined
  const rawArgs = Array.isArray(raw["args"])
    ? raw["args"].filter((item): item is string => typeof item === "string")
    : Array.isArray(raw["command"])
      ? raw["command"].slice(1).filter((item): item is string => typeof item === "string")
      : []
  if (command === undefined) {
    // OpenCode encodes the whole invocation as a command array.
    if (Array.isArray(raw["command"])) {
      const parts = raw["command"].filter((item): item is string => typeof item === "string")
      const [first, ...rest] = parts
      if (first === undefined) return ""
      return packageIdentity(first, rest) ?? parts.join(" ")
    }
    return ""
  }
  const packaged = packageIdentity(command, rawArgs)
  if (packaged !== undefined) return packaged
  if (rawArgs.length > 0) return `${command} ${rawArgs.join(" ")}`
  return command
}

/// npx/bunx invocations identify by package name, so `npx -y foo` in Claude
/// Code and `bunx foo` in OpenCode coalesce to the same server.
const packageIdentity = (command: string, args: ReadonlyArray<string>): string | undefined => {
  if (command !== "npx" && command !== "bunx") return undefined
  const yIndex = args.indexOf("-y")
  const pkg = args[yIndex >= 0 ? yIndex + 1 : 0]
  if (pkg !== undefined && !pkg.startsWith("-")) return pkg
  return undefined
}

/// Canonicalize URL identities so trivial variants (host case, trailing
/// slash) coalesce. Non-URL strings pass through untouched.
export const normalizeUrlIdentity = (identity: string): string => {
  if (!identity.startsWith("http://") && !identity.startsWith("https://")) return identity
  try {
    const url = new URL(identity)
    const pathname = url.pathname.replace(/\/+$/, "")
    return `${url.protocol}//${url.host}${pathname}${url.search}`
  } catch {
    return identity
  }
}
