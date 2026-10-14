export function baselineName(model: string): string {
  const safe = model.trim().replaceAll(/[^A-Za-z0-9]+/g, "_")
  if (!safe) throw new Error("empty machine model")
  return `baseline-${safe}.json`
}

export interface BenchOptions {
  saveBaseline: boolean
  compare: boolean
  againstMain: boolean
  passThrough: string[]
  help?: boolean
}

export function parseBenchArguments(argv: string[]): BenchOptions {
  const options: BenchOptions = {
    saveBaseline: false,
    compare: true,
    againstMain: false,
    passThrough: []
  }
  for (const argument of argv) {
    if (argument === "--save-baseline") options.saveBaseline = true
    else if (argument === "--no-compare") options.compare = false
    else if (argument === "--against-main") options.againstMain = true
    else if (argument === "--help" || argument === "-h") options.help = true
    else if (argument === "--out" || argument === "--baseline" || argument === "--build") {
      throw new Error(
        `${argument} is set by vnc:bench; run screen-sharing-rig vnc-bench directly to override it`
      )
    } else options.passThrough.push(argument)
  }
  return options
}

export function buildLabel(hash: string, dirty: boolean): string {
  return `${hash.trim().slice(0, 12)}${dirty ? "+dirty" : ""}`
}

export function runDirectoryName(date: Date): string {
  return date
    .toISOString()
    .replaceAll(":", "")
    .replace(/\.\d+Z$/, "Z")
}
