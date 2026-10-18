import { isoTimestamp, type HarnessUsageLimits } from "@codevisor/api"

const METRICS: Readonly<
  Record<string, { readonly label: string; readonly durationMinutes: number }>
> = {
  "five hour limit remaining": { label: "5-hour", durationMinutes: 300 },
  "weekly limit remaining": { label: "Weekly", durationMinutes: 10_080 }
}

const slug = (value: string): string =>
  value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")

const usageWindow = (line: string): HarnessUsageLimits["windows"][number] | undefined => {
  const columns = line.split("\t").map((column) => column.trim())
  if (columns.length !== 4) return undefined
  const [group = "", metric = "", remaining = "", resetAt = ""] = columns
  const known = METRICS[metric.toLowerCase()]
  const left = Number.parseFloat(remaining)
  if (group === "" || known === undefined || !remaining.endsWith("%") || Number.isNaN(left))
    return undefined
  const resets = Date.parse(resetAt)
  return {
    id: `${slug(group)}-${slug(known.label)}`,
    label: `${group} · ${known.label}`,
    usedPercent: Math.max(0, Math.min(100, 100 - left)),
    durationMinutes: known.durationMinutes,
    ...(Number.isNaN(resets) ? {} : { resetsAt: new Date(resets).toISOString() })
  }
}

export const agyUsageLimitsFrom = (stdout: string): HarnessUsageLimits => {
  const windows = stdout
    .split("\n")
    .filter((line) => line.includes("\t"))
    .map(usageWindow)
    .filter((window): window is NonNullable<typeof window> => window !== undefined)
  return {
    fetchedAt: isoTimestamp(),
    harnessId: "antigravity",
    state: windows.length > 0 ? "available" : "unavailable",
    windows,
    ...(windows.length > 0 ? {} : { detail: "Antigravity did not report usage limits." })
  }
}
