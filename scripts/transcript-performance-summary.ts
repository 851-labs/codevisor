import { readFile } from "node:fs/promises"
import { pathToFileURL } from "node:url"

export interface TranscriptRecord {
  name: string
  durationMS?: number
  values?: unknown
}

export interface TranscriptTiming {
  count: number
  p50MS: number
  p95MS: number
  maxMS: number
}

export interface TranscriptPerformanceSummary {
  timings: Record<string, TranscriptTiming>
  viewports: Record<string, unknown>
}

// These are CPU operation timings. Nested operations overlap; neither their
// sum nor the display-link callback duration measures total frame time.
export function summarizeTranscriptPerformance(
  records: readonly TranscriptRecord[]
): TranscriptPerformanceSummary {
  const groups = new Map<string, number[]>()
  const viewports: Record<string, unknown> = {}
  for (const record of records) {
    if (record.name.endsWith(".viewport")) viewports[record.name] = record.values
    const duration = record.durationMS
    if (!Number.isFinite(duration) || duration === undefined || duration < 0) continue
    const values = groups.get(record.name) ?? []
    values.push(duration)
    groups.set(record.name, values)
  }
  const timings: Record<string, TranscriptTiming> = {}
  for (const [name, values] of [...groups].sort(([a], [b]) => a.localeCompare(b))) {
    values.sort((a, b) => a - b)
    const percentile = (fraction: number) =>
      Math.round((values[Math.max(0, Math.ceil(values.length * fraction) - 1)] ?? 0) * 1000) / 1000
    timings[name] = {
      count: values.length,
      p50MS: percentile(0.5),
      p95MS: percentile(0.95),
      maxMS: percentile(1)
    }
  }
  return { timings, viewports }
}

async function main(paths: readonly string[]): Promise<void> {
  if (paths.length === 0)
    throw new Error("Usage: node scripts/transcript-performance-summary.ts <trace.jsonl> [...]")
  const summaries: Record<string, TranscriptPerformanceSummary> = {}
  for (const path of paths) {
    const source = await readFile(path, "utf8")
    const records = source
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line) as TranscriptRecord)
    summaries[path] = summarizeTranscriptPerformance(records)
  }
  process.stdout.write(`${JSON.stringify(summaries, null, 2)}\n`)
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href)
  await main(process.argv.slice(2))
