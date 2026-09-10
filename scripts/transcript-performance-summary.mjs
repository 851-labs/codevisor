import { readFile } from "node:fs/promises"
import { pathToFileURL } from "node:url"

// These are CPU operation timings. Nested operations overlap; neither their
// sum nor the display-link callback duration measures total frame time.
export function summarizeTranscriptPerformance(records) {
  const groups = new Map()
  const viewports = {}
  for (const record of records) {
    if (record.name.endsWith(".viewport")) viewports[record.name] = record.values
    if (!Number.isFinite(record.durationMS) || record.durationMS < 0) continue
    const values = groups.get(record.name) ?? []
    values.push(record.durationMS)
    groups.set(record.name, values)
  }
  const timings = {}
  for (const [name, values] of [...groups].sort(([a], [b]) => a.localeCompare(b))) {
    values.sort((a, b) => a - b)
    const percentile = (fraction) =>
      Math.round(values[Math.max(0, Math.ceil(values.length * fraction) - 1)] * 1000) / 1000
    timings[name] = {
      count: values.length,
      p50MS: percentile(0.5),
      p95MS: percentile(0.95),
      maxMS: percentile(1)
    }
  }
  return { timings, viewports }
}

async function main(paths) {
  if (paths.length === 0)
    throw new Error("Usage: node scripts/transcript-performance-summary.mjs <trace.jsonl> [...]")
  const summaries = {}
  for (const path of paths) {
    const source = await readFile(path, "utf8")
    const records = source.split("\n").filter(Boolean).map(JSON.parse)
    summaries[path] = summarizeTranscriptPerformance(records)
  }
  process.stdout.write(`${JSON.stringify(summaries, null, 2)}\n`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  await main(process.argv.slice(2))
