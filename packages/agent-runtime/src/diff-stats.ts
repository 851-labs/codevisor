import { diffLines } from "diff"
import type { DiffStat } from "@herdman/api"

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

export const sumDiffStats = (
  stats: ReadonlyArray<DiffStat>
): { added: number; removed: number } => {
  let added = 0
  let removed = 0
  for (const stat of stats) {
    added += stat.added
    removed += stat.removed
  }
  return { added, removed }
}
