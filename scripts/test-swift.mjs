import { spawnSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { fileURLToPath } from "node:url"

// TestStore installs a process-wide executor hook, even without an explicit
// withMainSerialExecutor call. Keep these suites out of unrelated tests' process.
// The two complementary selections run every test with normal parallelism.
// The list is data in packages/swift so `vnc:validate` (in the rig app) can read it too.
export const mainSerialExecutorSuites = JSON.parse(
  readFileSync(
    new URL("../packages/swift/main-serial-executor-suites.json", import.meta.url),
    "utf8"
  )
)

export const mainSerialExecutorFilter = `(${mainSerialExecutorSuites.join("|")})/`

export function runSwiftTests(args = [], run = spawnSync) {
  // Extra selectors could turn the isolated pass into a union with unrelated
  // tests. This command runs the full suites; only build options may be forwarded.
  for (const arg of args) {
    if (/^--(?:filter|skip|package-path|specifier)(?:=|$)/.test(arg) || arg === "-s") {
      throw new Error(`Test selection is managed by swift:test; cannot forward ${arg}`)
    }
  }
  const commands = [
    ["--package-path", "packages/swift", "--skip", mainSerialExecutorFilter],
    ["--package-path", "packages/swift", "--skip-build", "--filter", mainSerialExecutorFilter],
    ["--package-path", "apps/screen-sharing-rig"]
  ]
  for (const command of commands) {
    const result = run("swift", ["test", ...command, ...args], {
      cwd: fileURLToPath(new URL("..", import.meta.url)),
      stdio: "inherit"
    })
    if (result.error) throw result.error
    if (result.status !== 0) return result.status ?? 1
  }
  return 0
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = runSwiftTests(process.argv.slice(2))
}
