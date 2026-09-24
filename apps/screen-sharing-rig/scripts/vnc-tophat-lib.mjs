// Pure helpers for `bun run vnc:tophat` (apps/screen-sharing-rig/scripts/vnc-tophat.mjs).

export const machineFlows = ["loopback", "contabo"]

export function parseTophatArguments(argv) {
  const options = { machines: ["loopback"], build: true }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === "--machines") {
      const value = argv[index + 1]
      if (value === undefined) throw new Error("--machines needs a value")
      index += 1
      options.machines = value.split(",")
      const unknown = options.machines.find((machine) => !machineFlows.includes(machine))
      if (unknown)
        throw new Error(`unknown machine ${unknown}; choose from ${machineFlows.join(", ")}`)
    } else if (argument === "--no-build") options.build = false
    else if (argument === "--help" || argument === "-h") options.help = true
    else throw new Error(`Unknown argument ${argument}`)
  }
  return options
}

/// Steps are { name, ok, detail }; the run passes only if every step did.
export function summarize(steps) {
  const failed = steps.filter((step) => !step.ok)
  return {
    ok: steps.length > 0 && failed.length === 0,
    passed: steps.length - failed.length,
    failed
  }
}

/// `rig-ax window` prints "title<TAB>number<TAB>width<TAB>height".
export function parseWindow(line) {
  const [title, number, width, height] = line.trim().split("\t")
  const window = { title, number: Number(number), width: Number(width), height: Number(height) }
  if (!Number.isInteger(window.number) || window.number <= 0)
    throw new Error(`No window in ${JSON.stringify(line)}`)
  return window
}

/// A marker the loopback server's input log shows when the clipboard arrives;
/// non-Latin-1 on purpose, so it only survives the UTF-8 clipboard (851-2316).
export function clipboardToken(seed) {
  return `codevisor-tophat-${seed.toString(36)} 日本語 😀`
}
