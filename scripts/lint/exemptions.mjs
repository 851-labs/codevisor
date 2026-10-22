import { readFileSync } from "node:fs"
import { relative } from "node:path"
import { fileURLToPath } from "node:url"

export const repoRoot = fileURLToPath(new URL("../..", import.meta.url))

export const exemptionsPath = "scripts/lint/exemptions.json"

export const loadExemptions = () =>
  JSON.parse(readFileSync(new URL("exemptions.json", import.meta.url), "utf8"))

export const repoPath = (filename) => relative(repoRoot, filename).replaceAll("\\", "/")

const collapse = (text) => text.replaceAll(/\s+/g, " ").trim()

export function exemptionTracker(context, entries) {
  const file = repoPath(context.filename)
  const pending = entries.filter((entry) => entry.file === file)
  const matched = new Set()
  return {
    isExempt(node) {
      const code = collapse(context.sourceCode.getText(node))
      const entry = pending.find((candidate) => !matched.has(candidate) && candidate.code === code)
      if (entry === undefined) return false
      matched.add(entry)
      return true
    },
    reportStale() {
      for (const entry of pending.filter((candidate) => !matched.has(candidate))) {
        context.report({
          loc: { start: { line: 1, column: 0 }, end: { line: 1, column: 0 } },
          message: `Stale exemption in ${exemptionsPath}: "${entry.code}" is gone. Remove the entry.`
        })
      }
    }
  }
}
