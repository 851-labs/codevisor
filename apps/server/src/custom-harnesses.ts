import { harnessCatalog, type HarnessDefinition } from "@codevisor/agent-runtime"
import type { CustomHarnessSpec, CustomHarnessTestResult } from "@codevisor/api"
import { mkdir, readFile, rename, writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"

/// The server's handle on user-defined custom harnesses — injected into route
/// handling so tests can stub persistence and the ACP handshake probe.
export interface CustomHarnessStore {
  readonly list: () => Promise<ReadonlyArray<CustomHarnessSpec>>
  /// Replaces the whole list: persists the file, swaps the runtime catalog,
  /// and refreshes the environment so readiness reflects the new entries.
  readonly replace: (specs: ReadonlyArray<CustomHarnessSpec>) => Promise<void>
  /// Spawns the spec's command and performs the ACP initialize handshake.
  readonly test: (spec: CustomHarnessSpec) => Promise<CustomHarnessTestResult>
}

/// User-editable custom ACP harness store: `~/.codevisor/harnesses.json`.
/// The file is the source of truth (developers hand-edit and version it); the
/// API's PUT route rewrites it wholesale. Malformed content must never crash
/// server boot — bad entries are skipped with a warning.
///
/// Accepted shapes: `{ "harnesses": [entry, …] }` or a bare `[entry, …]`.
/// Entry: `{ id, name, command, args?, env? }`.

export const customHarnessesFileName = "harnesses.json"

export const customHarnessesPath = (root: string): string => join(root, customHarnessesFileName)

export interface CustomHarnessLoadResult {
  readonly specs: ReadonlyArray<CustomHarnessSpec>
  readonly definitions: ReadonlyArray<HarnessDefinition>
  /// Human-readable reasons for skipped entries (malformed, duplicate ids,
  /// builtin collisions) — callers log these; they are never fatal.
  readonly warnings: ReadonlyArray<string>
}

const emptyResult: CustomHarnessLoadResult = { definitions: [], specs: [], warnings: [] }

/// Custom entries get a stable id namespace-compatible with builtin ids but
/// restricted enough to be safe in profile directory names and event subjects.
const idPattern = /^[a-z0-9][a-z0-9._-]{0,63}$/i

const isStringRecord = (value: unknown): value is Record<string, string> =>
  typeof value === "object" &&
  value !== null &&
  !Array.isArray(value) &&
  Object.values(value).every((entry) => typeof entry === "string")

const parseSpec = (
  value: unknown,
  index: number,
  warnings: Array<string>
): CustomHarnessSpec | undefined => {
  const label = `harnesses[${index}]`
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    warnings.push(`${label}: not an object — skipped`)
    return undefined
  }
  const entry = value as Record<string, unknown>
  const id = entry.id
  if (typeof id !== "string" || !idPattern.test(id)) {
    warnings.push(`${label}: "id" must match ${String(idPattern)} — skipped`)
    return undefined
  }
  if (typeof entry.name !== "string" || entry.name.trim() === "") {
    warnings.push(`${label} (${id}): "name" must be a non-empty string — skipped`)
    return undefined
  }
  if (typeof entry.command !== "string" || entry.command.trim() === "") {
    warnings.push(`${label} (${id}): "command" must be a non-empty string — skipped`)
    return undefined
  }
  if (entry.args !== undefined) {
    if (!Array.isArray(entry.args) || entry.args.some((arg) => typeof arg !== "string")) {
      warnings.push(`${label} (${id}): "args" must be an array of strings — skipped`)
      return undefined
    }
  }
  if (entry.env !== undefined && !isStringRecord(entry.env)) {
    warnings.push(`${label} (${id}): "env" must be an object of string values — skipped`)
    return undefined
  }
  return {
    command: entry.command.trim(),
    id,
    name: entry.name.trim(),
    ...(entry.args === undefined ? {} : { args: entry.args as ReadonlyArray<string> }),
    ...(entry.env === undefined ? {} : { env: entry.env as Readonly<Record<string, string>> })
  }
}

export const customHarnessDefinition = (spec: CustomHarnessSpec): HarnessDefinition => ({
  detectBinaries: [spec.command],
  id: spec.id,
  launch: {
    args: spec.args === undefined ? [] : [...spec.args],
    command: spec.command,
    kind: "executable",
    ...(spec.env === undefined ? {} : { env: spec.env })
  },
  name: spec.name,
  provider: "acp",
  symbolName: "puzzlepiece.extension"
})

const specsToResult = (
  entries: ReadonlyArray<unknown>,
  warnings: Array<string>
): CustomHarnessLoadResult => {
  const builtinIds = new Set(harnessCatalog.map((definition) => definition.id))
  const seen = new Set<string>()
  const specs: Array<CustomHarnessSpec> = []
  entries.forEach((entry, index) => {
    const spec = parseSpec(entry, index, warnings)
    if (spec === undefined) return
    if (builtinIds.has(spec.id)) {
      warnings.push(
        `harnesses[${index}] (${spec.id}): id collides with a builtin harness — skipped`
      )
      return
    }
    if (seen.has(spec.id)) {
      warnings.push(`harnesses[${index}] (${spec.id}): duplicate id — skipped`)
      return
    }
    seen.add(spec.id)
    specs.push(spec)
  })
  return { definitions: specs.map(customHarnessDefinition), specs, warnings }
}

/// Validates a parsed JSON document (`{ "harnesses": [...] }` or a bare
/// array). Used by both the file loader and the PUT route so the API can
/// never persist entries the next boot would skip.
export const parseCustomHarnessDocument = (
  parsed: unknown,
  sourceLabel: string
): CustomHarnessLoadResult => {
  const entries = Array.isArray(parsed)
    ? parsed
    : typeof parsed === "object" &&
        parsed !== null &&
        Array.isArray((parsed as Record<string, unknown>).harnesses)
      ? ((parsed as Record<string, unknown>).harnesses as ReadonlyArray<unknown>)
      : undefined
  if (entries === undefined) {
    return {
      ...emptyResult,
      warnings: [`${sourceLabel}: expected { "harnesses": [...] } or a top-level array`]
    }
  }
  return specsToResult(entries, [])
}

/// Reads and validates the custom-harness file. Missing file → empty result;
/// unreadable/malformed file → empty result with a warning. Never throws.
export const loadCustomHarnesses = async (root: string): Promise<CustomHarnessLoadResult> => {
  const path = customHarnessesPath(root)
  let raw: string
  try {
    raw = await readFile(path, "utf8")
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code === "ENOENT") return emptyResult
    return { ...emptyResult, warnings: [`${path}: unreadable (${String(cause)})`] }
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch (cause) {
    /* v8 ignore next -- JSON.parse only throws Error values; String() guards the type. */
    const reason = cause instanceof Error ? cause.message : String(cause)
    return { ...emptyResult, warnings: [`${path}: invalid JSON (${reason})`] }
  }
  return parseCustomHarnessDocument(parsed, path)
}

/// Rewrites the whole file (the PUT route's semantics). Atomic via a sibling
/// temp file so a crash mid-write can't corrupt hand-maintained content.
export const saveCustomHarnesses = async (
  root: string,
  specs: ReadonlyArray<CustomHarnessSpec>
): Promise<void> => {
  const path = customHarnessesPath(root)
  await mkdir(dirname(path), { recursive: true })
  const body = `${JSON.stringify({ harnesses: specs }, null, 2)}\n`
  const staging = `${path}.tmp-${process.pid}`
  await writeFile(staging, body, "utf8")
  await rename(staging, path)
}
