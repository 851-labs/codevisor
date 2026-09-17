// Run swift-format over first-party Swift sources.
//   bun scripts/swift-format.ts fix     — format in place
//   bun scripts/swift-format.ts check   — lint mode; non-zero exit on findings
import { spawnSync } from "node:child_process"
import { readdirSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

// Paths stay relative to the repository root, the way `find apps packages`
// printed them, so swift-format's diagnostics keep their short filenames.
const root = dirname(dirname(fileURLToPath(import.meta.url)))

// The shell version filtered `find` output with -not -path. Applying the same
// patterns while walking also lets us prune the matching directories, which is
// equivalent — every file underneath them is excluded anyway — and avoids
// descending into a DerivedData or .build tree just to discard it.
function isExcluded(path: string): boolean {
  return (
    path.includes("/Vendor/") ||
    path.includes("/.build/") ||
    path.includes("DerivedData") ||
    path.includes("/tmp/")
  )
}

function swiftSources(directory: string): string[] {
  const found: string[] = []
  for (const entry of readdirSync(join(root, directory), { withFileTypes: true })) {
    const path = `${directory}/${entry.name}`
    // Like `find` without -L, a symlinked directory is never descended into.
    if (entry.isDirectory()) {
      if (!isExcluded(`${path}/`)) found.push(...swiftSources(path))
    } else if (entry.name.endsWith(".swift") && !isExcluded(path)) {
      found.push(path)
    }
  }
  return found
}

const modes: Record<string, string[]> = {
  fix: ["format", "--in-place", "--parallel"],
  check: ["lint", "--strict", "--parallel"]
}

const mode = process.argv[2] || "check"
const modeArguments = modes[mode]
if (!modeArguments) {
  console.error("usage: scripts/swift-format.ts [fix|check]")
  process.exit(2)
}

// `find` emitted directory order; sorting keeps runs and diagnostics stable.
const files = [...swiftSources("apps"), ...swiftSources("packages")].toSorted()
// The whole argument list is well under ARG_MAX, so this is the single
// swift-format invocation `xargs` was already assembling.
const result = spawnSync("swift", ["format", ...modeArguments, ...files], {
  cwd: root,
  stdio: "inherit"
})
if (result.error) throw result.error
process.exit(result.status ?? 1)
