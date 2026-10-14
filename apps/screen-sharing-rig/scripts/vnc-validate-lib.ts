export const defaults: { swiftFilter: string; benchArgs: string[]; machines: string } = {
  swiftFilter: "RFB|VNC|ScreenSharingDiagnostics|ScreenSharingViewerEndpoint",
  benchArgs: [],
  machines: "loopback"
}

export interface ValidateOptions {
  issue: string | undefined
  swiftFilter: string
  benchArgs: string[]
  machines: string
  skip: Set<string>
  saveBaseline: boolean
  help?: boolean
}

export function parseValidateArguments(argv: string[]): ValidateOptions {
  const options: ValidateOptions = {
    issue: undefined,
    swiftFilter: defaults.swiftFilter,
    benchArgs: [...defaults.benchArgs],
    machines: defaults.machines,
    skip: new Set(),
    saveBaseline: false
  }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]!
    const value = (): string => {
      const next = argv[index + 1]
      if (next === undefined) throw new Error(`${argument} needs a value`)
      index += 1
      return next
    }
    if (argument === "--issue") options.issue = value()
    else if (argument === "--swift-filter") options.swiftFilter = value()
    else if (argument === "--bench") options.benchArgs = value().split(" ").filter(Boolean)
    else if (argument === "--machines") options.machines = value()
    else if (argument === "--skip") {
      for (const layer of value().split(",")) {
        if (!layers.includes(layer))
          throw new Error(`unknown layer ${layer}; choose from ${layers.join(", ")}`)
        options.skip.add(layer)
      }
    } else if (argument === "--save-baseline") options.saveBaseline = true
    else if (argument === "--help" || argument === "-h") options.help = true
    else throw new Error(`Unknown argument ${argument}`)
  }
  if (!options.help && !/^\d+-\d+$/.test(options.issue ?? "")) {
    throw new Error("--issue is required, e.g. --issue 851-2311")
  }
  return options
}

export const layers = ["tests", "interop", "bench", "tophat"]

export function reportDirectory(date: Date, issue: string): string {
  return `docs/measurements/vnc/${date.toISOString().slice(0, 10)}-${issue}`
}

export interface LayerResult {
  layer: string
  ok?: boolean
  skipped?: boolean
  seconds?: number
  summary?: string
  detail?: string
}

export function renderReport({
  issue,
  build,
  machine,
  results
}: {
  issue: string
  build: string
  machine: string
  results: LayerResult[]
}): { ok: boolean; text: string } {
  const verdict =
    results.every((result) => result.ok || result.skipped) && results.some((r) => !r.skipped)
  const lines = [
    `# ${issue} — vnc:validate`,
    "",
    `Build \`${build}\` on ${machine}. Verdict: **${verdict ? "PASS" : "FAIL"}**.`,
    "",
    "| Layer | Result | Time | Summary |",
    "| --- | --- | ---: | --- |"
  ]
  for (const result of results) {
    const status = result.skipped ? "skipped" : result.ok ? "pass" : "FAIL"
    const time = result.skipped ? "–" : `${(result.seconds ?? 0).toFixed(0)} s`
    lines.push(
      `| ${result.layer} | ${status} | ${time} | ${(result.summary ?? "").replaceAll("|", "\\|")} |`
    )
  }
  for (const result of results) {
    if (result.detail) lines.push("", `## ${result.layer}`, "", result.detail.trim())
  }
  return { ok: verdict, text: `${lines.join("\n")}\n` }
}

export function lastLine(output: string, pattern: RegExp): string {
  return (
    output
      .split("\n")
      .findLast((line) => pattern.test(line))
      ?.trim() ?? ""
  )
}

export function testCount(output: string): { ran: number; passed: boolean } {
  const runs = [...output.matchAll(/Test run with (\d+) tests? in \d+ suites? (passed|failed)/g)]
  return {
    ran: runs.reduce((sum, match) => sum + Number(match[1]), 0),
    passed: runs.length > 0 && runs.every((match) => match[2] === "passed")
  }
}

export function benchFailure(current: string, main: string): string {
  return [
    block("vnc-bench failed (this build)", current),
    block("vnc-bench failed (origin/main)", main)
  ]
    .filter(Boolean)
    .join("\n")
}

function block(title: string, text: string): string {
  return text.trim() ? `**${title}**\n\n\`\`\`text\n${text.trim()}\n\`\`\`\n` : ""
}
