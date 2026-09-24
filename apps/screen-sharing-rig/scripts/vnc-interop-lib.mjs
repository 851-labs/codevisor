// Pure helpers for `bun run vnc:interop` (apps/screen-sharing-rig/scripts/vnc-interop.mjs): the L3
// real-server gate of docs/plans/vnc-validation.md.
import { createHash } from "node:crypto"

export const defaults = {
  geometry: "1024x768",
  password: "codevisor",
  rootColor: "336699",
  filter: "InteropTests",
  containerPort: 5901
}

export function parseInteropArguments(argv) {
  const options = { keep: false, filter: defaults.filter, geometry: defaults.geometry }
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    const value = () => {
      const next = argv[index + 1]
      if (next === undefined || next.startsWith("--")) throw new Error(`${argument} needs a value`)
      index += 1
      return next
    }
    if (argument === "--keep") options.keep = true
    else if (argument === "--filter") options.filter = value()
    else if (argument === "--geometry") {
      options.geometry = value()
      if (!/^\d+x\d+$/.test(options.geometry))
        throw new Error(`--geometry must be WxH, got ${options.geometry}`)
    } else if (argument === "--help" || argument === "-h") options.help = true
    else throw new Error(`Unknown argument ${argument}`)
  }
  return options
}

/// The image tag follows its build context, so a changed Dockerfile or
/// entrypoint always rebuilds and an unchanged one is reused.
export function imageTag(files) {
  const hash = createHash("sha256")
  for (const [name, contents] of Object.entries(files).toSorted(([a], [b]) => a.localeCompare(b))) {
    hash.update(name).update("\0").update(contents).update("\0")
  }
  return `codevisor-vnc-interop:${hash.digest("hex").slice(0, 12)}`
}

/// `docker port <container> 5901/tcp` prints one line per binding.
export function parseDockerPort(output) {
  for (const line of output.split("\n")) {
    const match = /^127\.0\.0\.1:(\d+)$/.exec(line.trim())
    if (match) return Number(match[1])
  }
  throw new Error(`No 127.0.0.1 binding in docker port output: ${JSON.stringify(output)}`)
}

export function interopEnvironment({ port, password, geometry, rootColor }) {
  return {
    VNC_TEST_HOST: "127.0.0.1",
    VNC_TEST_PORT: String(port),
    VNC_TEST_PASSWORD: password,
    VNC_TEST_GEOMETRY: geometry,
    VNC_TEST_ROOT_COLOR: rootColor
  }
}

/// A gate, not a smoke test: the suites must have run (not been skipped) and passed.
export function checkTestRun(output) {
  const runs = [...output.matchAll(/Test run with (\d+) tests? in \d+ suites? (passed|failed)/g)]
  const ran = runs.reduce((sum, match) => sum + Number(match[1]), 0)
  const failed = runs.some((match) => match[2] === "failed") || /\bfailed after\b/.test(output)
  const skipped = (output.match(/ skipped[ .]/g) ?? []).length
  const problems = []
  if (ran === 0) problems.push("no interop tests ran")
  if (skipped > 0) problems.push(`${skipped} interop test(s) skipped`)
  if (failed) problems.push("interop tests failed")
  return { ran, skipped, failed, ok: problems.length === 0, problems }
}
