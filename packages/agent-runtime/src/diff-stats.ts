import type { DiffStat } from "@codevisor/api"
import { diffLines } from "diff"

export const lineCount = (text: string): number => {
  if (text.length === 0) return 0
  const lines = text.split("\n")
  return lines[lines.length - 1] === "" ? lines.length - 1 : lines.length
}

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
    /* v8 ignore next */
    const count = change.count ?? 0
    if (change.added) added += count
    if (change.removed) removed += count
  }
  return { added, path, removed }
}

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

export const textsFromUnifiedDiff = (
  diff: string
): { oldText: string | null; newText: string } | undefined => {
  const oldLines: Array<string> = []
  const newLines: Array<string> = []
  let sawContent = false
  for (const line of diff.replace(/\n$/, "").split("\n")) {
    if (appendUnifiedDiffLine(line, oldLines, newLines)) sawContent = true
  }
  if (!sawContent) return undefined
  return {
    newText: `${newLines.join("\n")}\n`,
    oldText: oldLines.length === 0 ? null : `${oldLines.join("\n")}\n`
  }
}
