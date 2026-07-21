import type { McpTransport } from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { mkdir, readFile, rename, writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"
import * as jsonc from "jsonc-parser"
import { parse as parseToml, stringify as stringifyToml } from "smol-toml"
import { parse as parseYaml } from "yaml"

/// Filesystem seam for reading (and, for writable formats, surgically
/// editing) harness-owned config files. Mirrors the AgentSessionFileSystem
/// pattern (agent-runtime/agent-sessions.ts) so scanners are unit-testable
/// without touching a real home directory.
export interface NativeConfigFileSystem {
  /// Returns the file's contents, or undefined when it does not exist.
  /// Non-ENOENT failures (permissions, I/O) throw.
  readonly readFile: (path: string) => Promise<string | undefined>
  /// Write via temp-file-plus-rename in the same directory, creating parent
  /// directories as needed — a crash mid-write never truncates the original.
  readonly writeFileAtomic: (path: string, content: string) => Promise<void>
}

export const defaultNativeConfigFileSystem: NativeConfigFileSystem = {
  readFile: async (path) => {
    try {
      return await readFile(path, "utf8")
    } catch (cause) {
      if ((cause as NodeJS.ErrnoException).code === "ENOENT") return undefined
      throw cause
    }
  },
  writeFileAtomic: async (path, content) => {
    await mkdir(dirname(path), { recursive: true })
    const temp = join(dirname(path), `.${randomUUID()}.tmp`)
    await writeFile(temp, content, "utf8")
    await rename(temp, path)
  }
}

/// A native config edit Codevisor refuses to perform because it cannot be
/// done without risking damage to the user's file (entry defined in a shape
/// the surgical editors don't handle, or a post-edit verification mismatch).
export class NativeConfigUnsupportedError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "NativeConfigUnsupportedError"
  }
}

export interface NativePathEnvironment {
  readonly home: string
  readonly env?: Readonly<Record<string, string | undefined>>
}

/// Resolve a catalog `~/`-relative config path against a home directory,
/// honoring the env overrides harnesses themselves respect: CODEX_HOME
/// relocates `~/.codex/...` and XDG_CONFIG_HOME relocates `~/.config/...`.
export const resolveNativeConfigPath = (
  specPath: string,
  environment: NativePathEnvironment
): string => {
  const env = environment.env ?? {}
  const codexHome = env["CODEX_HOME"]
  if (codexHome !== undefined && codexHome !== "" && specPath.startsWith("~/.codex/")) {
    return join(codexHome, specPath.slice("~/.codex/".length))
  }
  const xdgConfigHome = env["XDG_CONFIG_HOME"]
  if (xdgConfigHome !== undefined && xdgConfigHome !== "" && specPath.startsWith("~/.config/")) {
    return join(xdgConfigHome, specPath.slice("~/.config/".length))
  }
  if (specPath.startsWith("~/")) {
    return join(environment.home, specPath.slice(2))
  }
  return specPath
}

/// Parse a harness config file tolerantly. JSON accepts comments and trailing
/// commas (Claude/VS Code-family configs are JSONC in practice). Throws when
/// the content cannot be read as an object at all — callers surface that as a
/// per-harness scan error, never a 500.
export const parseNativeConfig = (
  content: string,
  format: "json" | "toml" | "yaml"
): Record<string, unknown> => {
  if (content.trim() === "") return {}
  let parsed: unknown
  switch (format) {
    case "json": {
      // Comments and trailing commas are tolerated silently; anything jsonc
      // still reports is real malformation, not formatting looseness.
      const errors: Array<jsonc.ParseError> = []
      parsed = jsonc.parse(content, errors, { allowTrailingComma: true })
      const firstError = errors[0]
      if (firstError !== undefined) {
        throw new Error(
          `invalid JSON at offset ${firstError.offset}: ${jsonc.printParseErrorCode(firstError.error)}`
        )
      }
      break
    }
    case "toml":
      parsed = parseToml(content)
      break
    case "yaml":
      parsed = parseYaml(content)
      break
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`config root is not an object (${format})`)
  }
  return parsed as Record<string, unknown>
}

/// Walk a dotted key path ("mcp_servers", "a.b.c") through nested records.
/// Ported from add-mcp formats/utils.ts.
export const getNestedValue = (obj: Record<string, unknown>, path: string): unknown => {
  let current: unknown = obj
  for (const key of path.split(".")) {
    if (current !== null && typeof current === "object" && key in current) {
      current = (current as Record<string, unknown>)[key]
    } else {
      return undefined
    }
  }
  return current
}

/// Detect the indentation style of a JSONC document so surgical edits match
/// the user's formatting. Ported from add-mcp formats/json.ts.
export const detectIndent = (
  text: string
): { readonly tabSize: number; readonly insertSpaces: boolean } => {
  let result: { tabSize: number; insertSpaces: boolean } | null = null
  jsonc.visit(text, {
    onObjectProperty: (_property, offset, _length, startLine, startCharacter) => {
      if (result === null && startLine > 0 && startCharacter > 0) {
        const lineStart = text.lastIndexOf("\n", offset - 1) + 1
        const whitespace = text.slice(lineStart, offset)
        result = { insertSpaces: !whitespace.includes("\t"), tabSize: startCharacter }
      }
    }
  })
  return result ?? { insertSpaces: true, tabSize: 2 }
}

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

/// Remove one server entry from a JSONC document, preserving the user's
/// comments, indentation, and everything outside the single edited subtree.
/// Ported from add-mcp formats/json.ts — deliberately with NO
/// JSON.stringify-of-the-whole-file fallback: for files like ~/.claude.json
/// a full rewrite would destroy unrelated state formatting, so failures
/// refuse instead.
export const removeJsonConfigKey = (
  content: string,
  configKey: string,
  serverName: string
): string => {
  const edits = jsonc.modify(content, [...configKey.split("."), serverName], undefined, {
    formattingOptions: detectIndent(content)
  })
  /* v8 ignore next 4 -- jsonc.modify only returns no edits for an absent key, which callers pre-verify. */
  if (edits.length === 0) {
    throw new NativeConfigUnsupportedError(`No entry named ${serverName} to remove`)
  }
  return jsonc.applyEdits(content, edits)
}

/// Set a single value (server entry on restore, enable flag on toggle)
/// inside a JSONC document, preserving formatting everywhere else.
export const setJsonConfigValue = (
  content: string,
  path: ReadonlyArray<string>,
  value: unknown
): string => {
  const edits = jsonc.modify(content, [...path], value, {
    formattingOptions: detectIndent(content)
  })
  return jsonc.applyEdits(content, edits)
}

const escapeRegExp = (value: string): string => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")

/// Canonical JSON (sorted object keys) for structural before/after
/// comparison of parsed TOML documents.
const canonicalJson = (value: unknown): string => {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(",")}]`
  }
  if (value !== null && typeof value === "object" && !(value instanceof Date)) {
    const entries = Object.entries(value as Record<string, unknown>)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, item]) => `${JSON.stringify(key)}:${canonicalJson(item)}`)
    return `{${entries.join(",")}}`
  }
  // Parsed TOML values are strings, numbers, booleans, and dates — never
  // undefined — so stringify always yields a string here.
  return JSON.stringify(value)
}

/// The acceptable post-removal shapes. Removing the only `[parent.name]`
/// table also removes the implicit parent from the document, so both
/// "parent kept as an empty table" and "parent gone" verify as correct.
const withoutKeyVariants = (
  parsed: Record<string, unknown>,
  parentKey: string,
  name: string
): ReadonlyArray<Record<string, unknown>> => {
  const parent = parsed[parentKey]
  /* v8 ignore next -- callers verify the entry exists before editing. */
  if (parent === null || typeof parent !== "object") return [parsed]
  const { [name]: _removed, ...rest } = parent as Record<string, unknown>
  if (Object.keys(rest).length === 0) {
    const { [parentKey]: _parent, ...withoutParent } = parsed
    return [{ ...parsed, [parentKey]: {} }, withoutParent]
  }
  return [{ ...parsed, [parentKey]: rest }]
}

/// Remove `[parentKey.name]` (and its subtables like `[parentKey.name.env]`)
/// from a TOML document by text-level excision, verified structurally:
/// parse(before) minus the entry must deep-equal parse(after). Entries
/// defined as inline tables or dotted keys are refused — Codevisor never
/// re-serializes a whole TOML file, because that would destroy comments and
/// formatting (the reason @iarna/toml-style round-trips were rejected).
export const removeTomlTable = (content: string, parentKey: string, name: string): string => {
  const before = parseToml(content) as Record<string, unknown>
  const parent = before[parentKey]
  if (
    parent === null ||
    typeof parent !== "object" ||
    !(name in (parent as Record<string, unknown>))
  ) {
    throw new NativeConfigUnsupportedError(`No entry named ${name} to remove`)
  }

  // Match [mcp_servers.docs], [mcp_servers."docs"], and their subtables.
  const nameForms = `(?:${escapeRegExp(name)}|"${escapeRegExp(name)}")`
  const headerPattern = new RegExp(
    `^\\s*\\[${escapeRegExp(parentKey)}\\.${nameForms}(?:\\.[^\\]]+)?\\]\\s*(?:#.*)?$`
  )
  const anyHeaderPattern = /^\s*\[/

  const lines = content.split("\n")
  const remove = new Set<number>()
  let excised = false
  for (let index = 0; index < lines.length; index += 1) {
    if (!headerPattern.test(lines[index] as string)) continue
    excised = true
    // Find the section's end: the next table header or EOF…
    let end = lines.length
    for (let next = index + 1; next < lines.length; next += 1) {
      if (anyHeaderPattern.test(lines[next] as string)) {
        end = next
        break
      }
    }
    // …then trim back over trailing blanks and comments: those visually
    // belong to the NEXT section (or are spacing), so they survive.
    let last = end - 1
    while (last > index) {
      const line = (lines[last] as string).trim()
      if (line === "" || line.startsWith("#")) {
        last -= 1
        continue
      }
      break
    }
    for (let cut = index; cut <= last; cut += 1) remove.add(cut)
  }
  const kept = lines.filter((_, index) => !remove.has(index))
  if (!excised) {
    throw new NativeConfigUnsupportedError(
      `${name} is not defined as a standard [${parentKey}.${name}] table (inline tables and dotted keys can't be edited safely) — edit the file manually`
    )
  }
  const after = kept.join("\n")

  // Structural verification: the edit removed exactly the one entry.
  let reparsed: Record<string, unknown>
  try {
    reparsed = parseToml(after) as Record<string, unknown>
  } catch {
    throw new NativeConfigUnsupportedError(
      `Removing ${name} would corrupt the file — edit it manually`
    )
  }
  const reparsedCanonical = canonicalJson(reparsed)
  const acceptable = withoutKeyVariants(before, parentKey, name).some(
    (variant) => canonicalJson(variant) === reparsedCanonical
  )
  /* v8 ignore next 5 -- refusal-over-corruption backstop: the section-scoped excision has no known parse-valid-but-different outcome, but a false verifier here would silently damage user configs. */
  if (!acceptable) {
    throw new NativeConfigUnsupportedError(
      `Removing ${name} would change unrelated configuration — edit the file manually`
    )
  }
  return after
}

/// Append a `[parentKey.name]` table (restore). The block is stringified in
/// isolation and appended, so the rest of the document is never touched;
/// verified structurally afterwards like removeTomlTable.
export const appendTomlTable = (
  content: string,
  parentKey: string,
  name: string,
  fragment: Record<string, unknown>
): string => {
  const before = parseToml(content) as Record<string, unknown>
  const block = stringifyToml({ [parentKey]: { [name]: fragment } })
  const separator = content.trim() === "" ? "" : `${content.trimEnd()}\n\n`
  const after = `${separator}${block.trim()}\n`

  let reparsed: Record<string, unknown>
  try {
    reparsed = parseToml(after) as Record<string, unknown>
  } catch {
    /* v8 ignore next 3 -- stringifyToml output always reparses; kept as a refusal-over-corruption backstop. */
    throw new NativeConfigUnsupportedError(
      `Restoring ${name} would corrupt the file — edit it manually`
    )
  }
  const expected = {
    ...before,
    [parentKey]: {
      ...(before[parentKey] !== null && typeof before[parentKey] === "object"
        ? (before[parentKey] as Record<string, unknown>)
        : {}),
      [name]: fragment
    }
  }
  /* v8 ignore next 5 -- refusal-over-corruption backstop: stringifyToml of an isolated table appends faithfully, but a mismatch must refuse rather than write. */
  if (canonicalJson(reparsed) !== canonicalJson(expected)) {
    throw new NativeConfigUnsupportedError(
      `Restoring ${name} would change unrelated configuration — edit the file manually`
    )
  }
  return after
}
