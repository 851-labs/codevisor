import * as jsonc from "jsonc-parser"
import { parse as parseToml, stringify as stringifyToml } from "smol-toml"

import { isRecord } from "./mcp-guards.js"
import { detectIndent, NativeConfigUnsupportedError } from "./native-config-files.js"

export const removeJsonConfigKey = (
  content: string,
  configKey: string,
  serverName: string
): string => {
  const edits = jsonc.modify(content, [...configKey.split("."), serverName], undefined, {
    formattingOptions: detectIndent(content)
  })
  /* v8 ignore next 4 */
  if (edits.length === 0) {
    throw new NativeConfigUnsupportedError(`No entry named ${serverName} to remove`)
  }
  return jsonc.applyEdits(content, edits)
}

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

const canonicalJson = (value: unknown): string => {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJson).join(",")}]`
  }
  if (isRecord(value) && !(value instanceof Date)) {
    const entries = Object.entries(value)
      .toSorted(([a], [b]) => a.localeCompare(b))
      .map(([key, item]) => `${JSON.stringify(key)}:${canonicalJson(item)}`)
    return `{${entries.join(",")}}`
  }
  return JSON.stringify(value)
}

const withoutKeyVariants = (
  parsed: Record<string, unknown>,
  parentKey: string,
  name: string
): ReadonlyArray<Record<string, unknown>> => {
  const parent = parsed[parentKey]
  /* v8 ignore next */
  if (!isRecord(parent)) return [parsed]
  const { [name]: _removed, ...rest } = parent
  if (Object.keys(rest).length === 0) {
    const { [parentKey]: _parent, ...withoutParent } = parsed
    return [{ ...parsed, [parentKey]: {} }, withoutParent]
  }
  return [{ ...parsed, [parentKey]: rest }]
}

export const removeTomlTable = (content: string, parentKey: string, name: string): string => {
  const before = readTomlRemovalTarget(content, parentKey, name)
  const nameForms = `(?:${escapeRegExp(name)}|"${escapeRegExp(name)}")`
  const headerPattern = new RegExp(
    `^\\s*\\[${escapeRegExp(parentKey)}\\.${nameForms}(?:\\.[^\\]]+)?\\]\\s*(?:#.*)?$`
  )
  const anyHeaderPattern = /^\s*\[/

  const lines = content.split("\n")
  const after = exciseTomlSections(lines, headerPattern, anyHeaderPattern, parentKey, name)
  verifyTomlRemoval(before, after, parentKey, name)
  return after
}

const readTomlRemovalTarget = (
  content: string,
  parentKey: string,
  name: string
): Record<string, unknown> => {
  const before = parseToml(content)
  const parent = before[parentKey]
  if (!isRecord(parent) || !(name in parent)) {
    throw new NativeConfigUnsupportedError(`No entry named ${name} to remove`)
  }
  return before
}

const exciseTomlSections = (
  lines: Array<string>,
  headerPattern: RegExp,
  anyHeaderPattern: RegExp,
  parentKey: string,
  name: string
): string => {
  const remove = new Set<number>()
  let excised = false
  for (const [index, line] of lines.entries()) {
    if (!headerPattern.test(line)) continue
    excised = true
    const end = tomlSectionEnd(lines, index, anyHeaderPattern)
    const last = tomlSectionContentEnd(lines, index, end)
    for (let cut = index; cut <= last; cut += 1) remove.add(cut)
  }
  const kept = lines.filter((_, index) => !remove.has(index))
  if (!excised) {
    throw new NativeConfigUnsupportedError(
      `${name} is not defined as a standard [${parentKey}.${name}] table (inline tables and dotted keys can't be edited safely) — edit the file manually`
    )
  }
  return kept.join("\n")
}

const tomlSectionEnd = (lines: Array<string>, index: number, anyHeaderPattern: RegExp): number => {
  const offset = lines.slice(index + 1).findIndex((line) => anyHeaderPattern.test(line))
  return offset === -1 ? lines.length : index + 1 + offset
}

const tomlSectionContentEnd = (lines: Array<string>, index: number, end: number): number => {
  const offset = lines.slice(index + 1, end).findLastIndex((line) => {
    const trimmed = line.trim()
    return trimmed !== "" && !trimmed.startsWith("#")
  })
  return index + 1 + offset
}

const parseTomlAfterRemoval = (after: string, name: string): Record<string, unknown> => {
  try {
    return parseToml(after)
  } catch {
    throw new NativeConfigUnsupportedError(
      `Removing ${name} would corrupt the file — edit it manually`
    )
  }
}

const verifyTomlRemoval = (
  before: Record<string, unknown>,
  after: string,
  parentKey: string,
  name: string
): void => {
  const reparsed = parseTomlAfterRemoval(after, name)
  const reparsedCanonical = canonicalJson(reparsed)
  const acceptable = withoutKeyVariants(before, parentKey, name).some(
    (variant) => canonicalJson(variant) === reparsedCanonical
  )
  /* v8 ignore next 5 */
  if (!acceptable) {
    throw new NativeConfigUnsupportedError(
      `Removing ${name} would change unrelated configuration — edit the file manually`
    )
  }
}

export const appendTomlTable = (
  content: string,
  parentKey: string,
  name: string,
  fragment: Record<string, unknown>
): string => {
  const before = parseToml(content)
  const block = stringifyToml({ [parentKey]: { [name]: fragment } })
  const separator = content.trim() === "" ? "" : `${content.trimEnd()}\n\n`
  const after = `${separator}${block.trim()}\n`

  verifyTomlRestoration(before, after, parentKey, name, fragment)
  return after
}

const parseTomlAfterRestoration = (after: string, name: string): Record<string, unknown> => {
  try {
    return parseToml(after)
  } catch {
    /* v8 ignore next 3 */
    throw new NativeConfigUnsupportedError(
      `Restoring ${name} would corrupt the file — edit it manually`
    )
  }
}

const restoredTomlDocument = (
  before: Record<string, unknown>,
  parentKey: string,
  name: string,
  fragment: Record<string, unknown>
): Record<string, unknown> => {
  const parent = before[parentKey]
  return {
    ...before,
    [parentKey]: {
      ...(isRecord(parent) ? parent : {}),
      [name]: fragment
    }
  }
}

const verifyTomlRestoration = (
  before: Record<string, unknown>,
  after: string,
  parentKey: string,
  name: string,
  fragment: Record<string, unknown>
): void => {
  const reparsed = parseTomlAfterRestoration(after, name)
  const expected = restoredTomlDocument(before, parentKey, name, fragment)
  /* v8 ignore next 5 */
  if (canonicalJson(reparsed) !== canonicalJson(expected)) {
    throw new NativeConfigUnsupportedError(
      `Restoring ${name} would change unrelated configuration — edit the file manually`
    )
  }
}
