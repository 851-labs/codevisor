import * as jsonc from "jsonc-parser"
import { parse as parseToml, stringify as stringifyToml } from "smol-toml"
import { detectIndent, NativeConfigUnsupportedError } from "./native-config-files.js"

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
