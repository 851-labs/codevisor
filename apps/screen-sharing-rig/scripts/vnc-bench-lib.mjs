// Pure helpers for `bun run vnc:bench` (apps/screen-sharing-rig/scripts/vnc-bench.mjs).

/// "Mac16,6" → "Mac16_6": the baseline file for this machine.
export function baselineName(model) {
  const safe = model.trim().replaceAll(/[^A-Za-z0-9]+/g, "_")
  if (!safe) throw new Error("empty machine model")
  return `baseline-${safe}.json`
}

/// Splits wrapper flags from the ones passed through to `screen-sharing-rig vnc-bench`.
export function parseBenchArguments(argv) {
  const options = { saveBaseline: false, compare: true, againstMain: false, passThrough: [] }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
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

/// `git describe`-like build label: short hash, "+dirty" with local changes.
export function buildLabel(hash, dirty) {
  return `${hash.trim().slice(0, 12)}${dirty ? "+dirty" : ""}`
}

export function runDirectoryName(date) {
  return date
    .toISOString()
    .replaceAll(":", "")
    .replace(/\.\d+Z$/, "Z")
}
