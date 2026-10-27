#!/usr/bin/env node
import { spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync
} from "node:fs"
import { homedir, tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

export const baselineFile = ".swiftlint-baseline.json"
export const swiftLintVersion = "0.65.1"

const macRelease = {
  asset: "portable_swiftlint.zip",
  sha256: "c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"
}
const releases = {
  "darwin-arm64": macRelease,
  "darwin-x64": macRelease,
  "linux-arm64": {
    asset: "swiftlint_linux_arm64.zip",
    sha256: "9ffa52f478e6d8eb485d37d14715ffac90abc81c58f3370d598bf75be05605f8"
  },
  "linux-x64": {
    asset: "swiftlint_linux_amd64.zip",
    sha256: "caeed6f4a679c35539ffaf124f6c4ab4a8416917f7d8796279dc52b74026059d"
  }
}
const artifactsRoot = join(homedir(), ".codevisor-development", "artifacts", "swiftlint")

function run(command, args) {
  const { status } = spawnSync(command, args, { stdio: ["ignore", "ignore", "inherit"] })
  if (status !== 0) throw new Error(`${command} ${args.join(" ")} failed`)
}

export function swiftLint() {
  const platform = `${process.platform}-${process.arch}`
  const release = releases[platform]
  if (release === undefined)
    throw new Error(`SwiftLint ${swiftLintVersion} has no ${platform} build`)
  const installed = join(artifactsRoot, swiftLintVersion)
  const binary = join(installed, "swiftlint")
  if (existsSync(binary)) return binary
  mkdirSync(artifactsRoot, { recursive: true })
  const staging = mkdtempSync(join(artifactsRoot, "download-"))
  try {
    const archive = join(staging, release.asset)
    run("curl", [
      "-fsSL",
      "--retry",
      "3",
      "-o",
      archive,
      `https://github.com/realm/SwiftLint/releases/download/${swiftLintVersion}/${release.asset}`
    ])
    const digest = createHash("sha256").update(readFileSync(archive)).digest("hex")
    if (digest !== release.sha256) {
      throw new Error(`${release.asset} has SHA-256 ${digest}, expected ${release.sha256}`)
    }
    run("unzip", ["-q", archive, "swiftlint", "-d", join(staging, "bin")])
    try {
      renameSync(join(staging, "bin"), installed)
    } catch (error) {
      if (!existsSync(binary)) throw error
    }
    return binary
  } finally {
    rmSync(staging, { recursive: true, force: true })
  }
}

const entryKey = ({ violation: { location, reason } }) =>
  [location.file, String(location.line).padStart(6, "0"), reason].join("\0")

const byEntryKey = (left, right) => {
  if (entryKey(left) < entryKey(right)) return -1
  return entryKey(left) > entryKey(right) ? 1 : 0
}

const withSortedKeys = (_, value) =>
  value === null || typeof value !== "object" || Array.isArray(value)
    ? value
    : Object.fromEntries(
        Object.entries(value).toSorted(([left], [right]) => left.localeCompare(right))
      )

export function lint(root, stdio = "inherit") {
  const result = spawnSync(
    swiftLint(),
    ["lint", "--quiet", "--strict", "--baseline", baselineFile],
    {
      cwd: root,
      stdio
    }
  )
  return result.status ?? 1
}

export function writeBaseline(root) {
  const swiftlint = swiftLint()
  const scratch = mkdtempSync(join(tmpdir(), "swiftlint-baseline-"))
  try {
    const written = join(scratch, "baseline.json")
    spawnSync(swiftlint, ["lint", "--quiet", "--strict", "--write-baseline", written], {
      cwd: root,
      stdio: "ignore"
    })
    const entries = JSON.parse(readFileSync(written, "utf8")).toSorted(byEntryKey)
    writeFileSync(join(root, baselineFile), `${JSON.stringify(entries, withSortedKeys, 2)}\n`)
    return entries.length
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
}

const repoRoot = fileURLToPath(new URL("..", import.meta.url))

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [command] = process.argv.slice(2)
  if (command === "lint") {
    process.exitCode = lint(repoRoot)
  } else if (command === "write") {
    console.log(`Wrote ${writeBaseline(repoRoot)} grandfathered violations to ${baselineFile}`)
  } else {
    throw new Error("usage: swift-lint.mjs lint | write")
  }
}
