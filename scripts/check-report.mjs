import { appendFileSync, readFileSync } from "node:fs"

const failureTailLines = 200

export function checkReporter(environment = process.env) {
  if (environment.GITHUB_ACTIONS === "true") return githubReporter(environment.GITHUB_STEP_SUMMARY)
  return terminalReporter()
}

function terminalReporter() {
  return {
    streamsOutput: false,
    runsLanesInParallel: true,
    started: (entry) => console.log(`→ ${entry.step.name} (${entry.reason})`),
    passed: (result) => console.log(`✓ ${result.step.name} ${seconds(result)}`),
    failed: (result) => {
      console.log(`\n✗ ${result.step.name} failed after ${seconds(result)}`)
      console.log(logTail(result.log))
    },
    finished: (results, plan, totalSeconds) =>
      console.log(summaryLines(results, plan, totalSeconds))
  }
}

function githubReporter(summaryPath) {
  return {
    streamsOutput: true,
    runsLanesInParallel: false,
    started: (entry) => console.log(`::group::${entry.step.name} (${entry.reason})`),
    passed: (result) => {
      console.log("::endgroup::")
      console.log(`✓ ${result.step.name} ${seconds(result)}`)
    },
    failed: (result) => {
      console.log("::endgroup::")
      console.log(
        `::error title=${result.step.name} failed::${result.step.name} failed after ${seconds(result)}; its output is in the group above`
      )
    },
    finished: (results, plan, totalSeconds) => {
      console.log(summaryLines(results, plan, totalSeconds))
      if (summaryPath) appendFileSync(summaryPath, summaryTable(results, plan, totalSeconds))
    }
  }
}

function summaryLines(results, plan, totalSeconds) {
  const rows = plan.map(({ step }) => {
    const result = resultFor(results, step)
    return `  ${statusMark(result)} ${step.name.padEnd(34)}${statusDetail(result)}`
  })
  return ["\nChecks", ...rows, `Total ${totalSeconds.toFixed(1)}s`].join("\n")
}

function summaryTable(results, plan, totalSeconds) {
  const rows = plan.map(({ step }) => {
    const result = resultFor(results, step)
    return `| ${statusMark(result)} | \`${step.name}\` | ${statusDetail(result)} |`
  })
  return [
    "### Checks",
    "",
    "| | Check | Result |",
    "|---|---|---|",
    ...rows,
    "",
    `Total ${totalSeconds.toFixed(1)}s`,
    ""
  ].join("\n")
}

function resultFor(results, step) {
  return results.find((candidate) => candidate.step === step)
}

function statusMark(result) {
  if (result.status === "passed") return "✓"
  return result.status === "failed" ? "✗" : "-"
}

function statusDetail(result) {
  if (result.status === "passed") return seconds(result)
  if (result.status === "failed") return `failed (${result.log})`
  if (result.status === "cancelled") return "cancelled"
  return `skipped: ${result.reason}`
}

function seconds(result) {
  return `${result.seconds.toFixed(1)}s`
}

function logTail(path) {
  const lines = readFileSync(path, "utf8").trimEnd().split("\n")
  const tail = lines.slice(-failureTailLines).join("\n")
  if (lines.length <= failureTailLines) return tail

  return `… ${lines.length - failureTailLines} earlier lines in ${path}\n${tail}`
}
