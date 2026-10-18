import { field, stringField } from "../unknown-values.js"
import type { CliDeps, StatusOptions } from "./support.js"

interface HarnessSummary {
  readonly id: string
  readonly state: string
  readonly detail?: string
  readonly version?: string
  readonly path?: string
}

export const harnessSummaries = (body: unknown): ReadonlyArray<HarnessSummary> => {
  if (!Array.isArray(body)) return []
  return body.flatMap((entry) => {
    const id = stringField(entry, "id")
    if (id === undefined) return []
    const readiness = field(entry, "readiness")
    const detail = stringField(readiness, "detail")
    const version = stringField(readiness, "version")
    const path = stringField(readiness, "path")
    const summary: { -readonly [Key in keyof HarnessSummary]: HarnessSummary[Key] } = {
      id,
      state: stringField(readiness, "state") ?? "unknown"
    }
    if (detail !== undefined) summary.detail = detail
    if (version !== undefined) summary.version = version
    if (path !== undefined) summary.path = path
    return [summary]
  })
}

const reported = (value: unknown): string => (typeof value === "string" ? value : "unknown")

export const printUnavailableStatus = (
  deps: CliDeps,
  options: StatusOptions,
  port: number
): void => {
  if (options.json === true) {
    deps.log(
      JSON.stringify({ running: false, port, installedVersion: deps.installedVersion() ?? null })
    )
  } else {
    deps.log(`Codevisor server is not running on port ${port}`)
    const installed = deps.installedVersion()
    if (installed !== undefined) deps.log(`Installed version: ${installed}`)
    deps.log("Start it with: codevisor start")
  }
}

const printHarnesses = (deps: CliDeps, harnesses: ReadonlyArray<HarnessSummary>): void => {
  if (harnesses.length === 0) return
  deps.log("  harnesses:")
  for (const harness of harnesses) {
    const version = harness.version === undefined ? "" : ` ${harness.version}`
    const location = harness.path === undefined ? "" : ` (${harness.path})`
    const detail = harness.detail === undefined ? "" : ` — ${harness.detail}`
    deps.log(`    ${harness.id}: ${harness.state}${version}${location}${detail}`)
  }
}

export const printRunningStatus = (
  deps: CliDeps,
  options: StatusOptions,
  port: number,
  manifest: Readonly<Record<string, unknown>>,
  harnesses: ReadonlyArray<HarnessSummary>
): void => {
  if (options.json === true) {
    deps.log(
      JSON.stringify({
        running: true,
        port,
        name: manifest.name,
        version: manifest.version,
        serverId: manifest.id,
        machineId: manifest.machineId,
        platform: manifest.platform,
        arch: manifest.arch,
        hostname: manifest.hostname,
        harnesses
      })
    )
    return
  }
  deps.log(`Codevisor server ${String(manifest.version)} is running on port ${port}`)
  deps.log(`  name:      ${String(manifest.name)}`)
  deps.log(`  machine:   ${reported(manifest.hostname)} (${reported(manifest.machineId)})`)
  deps.log(`  platform:  ${String(manifest.platform)}/${reported(manifest.arch)}`)
  printHarnesses(deps, harnesses)
}
