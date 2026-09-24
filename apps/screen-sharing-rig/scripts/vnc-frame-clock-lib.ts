// Argument parsing and the markdown report for `bun run vnc:frame-clock` (851-2358).

export const defaultFrameClockApps = ["com.codevisor.ScreenSharingRig", "com.apple.ScreenSharing"]
export const frameClockModes = ["video", "scroll", "type", "still"] as const
export type FrameClockMode = (typeof frameClockModes)[number]

export type FrameClockOptions = {
  apps: string[]
  seconds: number
  mode: FrameClockMode
  port: number
  out?: string
  label?: string
}

/// One app's line of `screen-sharing-rig frame-clock` output.
export type FrameClockApp = {
  window?: string
  captures?: number
  calibrated?: boolean
  updatesPerSecond?: number
  hostFramesShown?: number
  gapP50Ms?: number
  gapP95Ms?: number
  gapMaxMs?: number
  tornFraction?: number
  unreadableFraction?: number
  failure?: string
}

export type FrameClockSummary = {
  seconds: number
  apps: Record<string, FrameClockApp>
  lags: Record<string, { p50Ms: number; p95Ms: number }>
}

export function parseFrameClockArguments(argv: string[]): FrameClockOptions | "help" {
  if (argv.includes("--help")) return "help"
  const options: FrameClockOptions = { apps: [], seconds: 60, mode: "video", port: 8765 }
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]
    const value = argv[index + 1]
    if (value === undefined) throw new Error(`${key} needs a value`)
    switch (key) {
      case "--app":
        options.apps.push(value)
        break
      case "--seconds":
        options.seconds = positive(key, value)
        break
      case "--port":
        options.port = positive(key, value)
        break
      case "--mode":
        if (!(frameClockModes as readonly string[]).includes(value)) {
          throw new Error(`--mode is one of ${frameClockModes.join(", ")}`)
        }
        options.mode = value as FrameClockMode
        break
      case "--out":
        options.out = value
        break
      case "--label":
        options.label = value
        break
      default:
        throw new Error(`unknown option ${key}`)
    }
  }
  if (options.apps.length === 0) options.apps = [...defaultFrameClockApps]
  return options
}

function positive(key: string | undefined, value: string): number {
  const number = Number(value)
  if (!Number.isFinite(number) || number <= 0) throw new Error(`${key} must be a positive number`)
  return number
}

const shortName: Record<string, string> = {
  "com.codevisor.ScreenSharingRig": "Codevisor rig",
  "com.apple.ScreenSharing": "Apple Screen Sharing"
}

function name(app: string): string {
  return shortName[app] ?? app
}

function cell(value: number | undefined, digits = 0, suffix = ""): string {
  return value === undefined ? "–" : `${value.toFixed(digits)}${suffix}`
}

/// The report: one row per viewer, then each viewer's lag behind the others.
export function frameClockReport(
  summary: FrameClockSummary,
  context: { mode: FrameClockMode; label?: string }
): string {
  const lines = [
    `# Frame clock${context.label ? ` — ${context.label}` : ""}`,
    "",
    `Workload \`${context.mode}\`, ${summary.seconds} s after every window calibrated. Host frames count at 60/s.`,
    "",
    "| viewer | window | updates/s | host frames shown | gap p50 ms | gap p95 ms | gap max ms | torn | unreadable |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
  ]
  for (const [app, row] of Object.entries(summary.apps)) {
    lines.push(
      `| ${name(app)} | ${row.window ?? "–"} | ${cell(row.updatesPerSecond, 2)} | ${cell(
        row.hostFramesShown === undefined ? undefined : row.hostFramesShown * 100,
        0,
        "%"
      )} | ${cell(row.gapP50Ms)} | ${cell(row.gapP95Ms)} | ${cell(row.gapMaxMs)} | ${cell(
        row.tornFraction === undefined ? undefined : row.tornFraction * 100,
        0,
        "%"
      )} | ${cell(row.unreadableFraction === undefined ? undefined : row.unreadableFraction * 100, 0, "%")} |`
    )
  }
  const lags = Object.entries(summary.lags).filter(([, lag]) => lag.p50Ms >= 0)
  if (lags.length > 0) {
    lines.push("", "| lag | p50 ms | p95 ms |", "| --- | ---: | ---: |")
    for (const [pair, lag] of lags) {
      const [behind, reference] = pair.split(" behind ")
      lines.push(
        `| ${name(behind ?? pair)} behind ${name(reference ?? "")} | ${lag.p50Ms} | ${lag.p95Ms} |`
      )
    }
  }
  return lines.join("\n") + "\n"
}
