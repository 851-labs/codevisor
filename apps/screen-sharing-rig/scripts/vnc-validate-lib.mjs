// Pure helpers for `bun run vnc:validate` (apps/screen-sharing-rig/scripts/vnc-validate.mjs): the one
// gate every VNC change passes (docs/plans/vnc-validation.md).

export const defaults = {
  // Every VNC-touching Swift suite: RFB/VNC protocol and sessions, the
  // reference server and shaping, and the product diagnostics.
  swiftFilter: "RFB|VNC|ScreenSharingDiagnostics|ScreenSharingViewerEndpoint",
  benchArgs: [],
  machines: "loopback"
}

export function parseValidateArguments(argv) {
  const options = {
    issue: undefined,
    swiftFilter: defaults.swiftFilter,
    benchArgs: [...defaults.benchArgs],
    machines: defaults.machines,
    skip: new Set(),
    saveBaseline: false
  }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    const value = () => {
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

export function reportDirectory(date, issue) {
  return `docs/measurements/vnc/${date.toISOString().slice(0, 10)}-${issue}`
}

/// Results are { layer, ok, skipped, seconds, summary, detail }.
export function renderReport({ issue, build, machine, results }) {
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
    const time = result.skipped ? "–" : `${result.seconds.toFixed(0)} s`
    lines.push(
      `| ${result.layer} | ${status} | ${time} | ${(result.summary ?? "").replaceAll("|", "\\|")} |`
    )
  }
  for (const result of results.filter((r) => r.detail)) {
    lines.push("", `## ${result.layer}`, "", result.detail.trim())
  }
  return { ok: verdict, text: `${lines.join("\n")}\n` }
}

/// The last line matching `pattern`, for a layer's one-line summary.
export function lastLine(output, pattern) {
  return (
    output
      .split("\n")
      .findLast((line) => pattern.test(line))
      ?.trim() ?? ""
  )
}

/// One `swift test` invocation can run several test binaries: total them.
export function testCount(output) {
  const runs = [...output.matchAll(/Test run with (\d+) tests? in \d+ suites? (passed|failed)/g)]
  return {
    ran: runs.reduce((sum, match) => sum + Number(match[1]), 0),
    passed: runs.length > 0 && runs.every((match) => match[2] === "passed")
  }
}

/// The bench layer's failure text for the report: this build's bench-error.txt
/// and origin/main's, each fenced so its lines survive Markdown (851-2337).
export function benchFailure(current, main) {
  const block = (title, text) =>
    text.trim() ? `**${title}**\n\n\`\`\`text\n${text.trim()}\n\`\`\`\n` : ""
  return [
    block("vnc-bench failed (this build)", current),
    block("vnc-bench failed (origin/main)", main)
  ]
    .filter(Boolean)
    .join("\n")
}
