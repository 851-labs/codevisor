import type { DiffStat } from "@codevisor/api"
import { diffLines } from "diff"

/** Number of lines in `text`, where an empty string has zero lines and a
 *  trailing newline does not open a final empty line. */
export const lineCount = (text: string): number => {
  if (text.length === 0) return 0
  const lines = text.split("\n")
  return lines[lines.length - 1] === "" ? lines.length - 1 : lines.length
}

/** Line-diff `oldText` → `newText` (Myers, via the `diff` package) and count
 *  added/removed lines. `oldText` nullish means a file creation. */
export const diffStatsFromTexts = (
  path: string,
  oldText: string | null | undefined,
  newText: string
): DiffStat => {
  const previous = oldText ?? ""
  if (previous === newText) return { added: 0, path, removed: 0 }
  let added = 0
  let removed = 0
  for (const change of diffLines(previous, newText)) {
    /* v8 ignore next -- diffLines always populates count; the type is just optional. */
    const count = change.count ?? 0
    if (change.added) added += count
    if (change.removed) removed += count
  }
  return { added, path, removed }
}

/** Count added/removed lines in a unified diff body, ignoring file headers
 *  (`+++`/`---`) and hunk markers (`@@`). */
export const diffStatsFromUnified = (path: string, unifiedDiff: string): DiffStat => {
  let added = 0
  let removed = 0
  for (const line of unifiedDiff.split("\n")) {
    if (line.startsWith("+++") || line.startsWith("---")) continue
    if (line.startsWith("+")) added += 1
    else if (line.startsWith("-")) removed += 1
  }
  return { added, path, removed }
}

const appendUnifiedDiffLine = (
  line: string,
  oldLines: Array<string>,
  newLines: Array<string>
): boolean => {
  if (line.startsWith("+++") || line.startsWith("---") || line.startsWith("@@")) return false
  if (line.startsWith("+")) {
    newLines.push(line.slice(1))
    return true
  } else if (line.startsWith("-")) {
    oldLines.push(line.slice(1))
    return true
  } else {
    const text = line.startsWith(" ") ? line.slice(1) : line
    oldLines.push(text)
    newLines.push(text)
    return false
  }
}

/// Reconstructs old/new text from a unified diff body so the client's DiffView
/// can render it. Hunk headers reset nothing here — the reconstruction is a
/// display approximation covering the changed regions and their context.
export const textsFromUnifiedDiff = (
  diff: string
): { oldText: string | null; newText: string } | undefined => {
  const oldLines: Array<string> = []
  const newLines: Array<string> = []
  let sawContent = false
  // A patch's final newline ends its last line; it is not an empty line.
  for (const line of diff.replace(/\n$/, "").split("\n")) {
    if (appendUnifiedDiffLine(line, oldLines, newLines)) sawContent = true
  }
  if (!sawContent) return undefined
  return {
    newText: `${newLines.join("\n")}\n`,
    oldText: oldLines.length === 0 ? null : `${oldLines.join("\n")}\n`
  }
}
