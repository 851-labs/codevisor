import { execFileSync, spawn, spawnSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import { availableParallelism } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { developmentLayout } from "./dev-layout.mjs"
import { prepareSwiftPackage } from "./swift-artifacts.mjs"

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

// Every suite uses Swift Testing, which test-swift.test.mjs enforces.
// Without XCTest, each run skips a ~3.5s XCTest discovery pass over every test
// bundle.
export const swiftTestingOnly = ["--disable-xctest"]

// The Swift packages this command tests, each built into its own .build.
// `--only=<path>` narrows a run to some of them; `bun run check` uses it to
// test only the packages a change can affect.
export const swiftTestPackages = ["packages/swift", "apps/screen-sharing-rig"]

const repoRoot = fileURLToPath(new URL("..", import.meta.url))

export async function runSwiftTests(
  args = [],
  { run = spawnSync, runBundles = runTestBundles } = {},
  packagePaths = swiftTestPackages
) {
  // Extra selectors could turn the isolated pass into a union with unrelated
  // tests. This command runs the full suites; only build options may be forwarded.
  for (const arg of args) {
    if (/^--(?:filter|skip|package-path|specifier)(?:=|$)/.test(arg) || arg === "-s") {
      throw new Error(`Test selection is managed by swift:test; cannot forward ${arg}`)
    }
  }
  const steps = packagePaths.flatMap((packagePath) =>
    packagePath === "packages/swift"
      ? [
          { swift: ["build", "--build-tests", "--package-path", packagePath] },
          { bundles: packagePath, selection: ["--skip", mainSerialExecutorFilter] },
          {
            swift: ["test", "--package-path", packagePath, "--skip-build"],
            selection: ["--filter", mainSerialExecutorFilter]
          }
        ]
      : [{ swift: ["test", "--package-path", packagePath] }]
  )
  for (const step of steps) {
    const selected = [...(step.selection ?? []), ...swiftTestingOnly, ...args]
    const status =
      step.bundles === undefined
        ? swiftStatus(
            run("swift", [...step.swift, ...selected], { cwd: repoRoot, stdio: "inherit" })
          )
        : await runBundles(step.bundles, selected, run)
    if (status !== 0) return status
  }
  return 0
}

function swiftStatus(result) {
  if (result.error) throw result.error
  return result.status ?? 1
}

/// Runs a built package's test bundles several at a time. `swift test` runs
/// them one after another, which for packages/swift takes ~12s instead of ~5s.
/// It launches each through SwiftPM's own testing helper, exactly as `swift
/// test` does, and falls back to `swift test` where that helper or the bundles
/// are not where this toolchain puts them.
export async function runTestBundles(packagePath, selection, run = spawnSync) {
  const fallback = () =>
    swiftStatus(
      run("swift", ["test", "--package-path", packagePath, "--skip-build", ...selection], {
        cwd: repoRoot,
        stdio: "inherit"
      })
    )
  const toolchain = dirname(
    dirname(execFileSync("xcrun", ["--find", "swift"], { encoding: "utf8" }).trim())
  )
  const helper = join(toolchain, "libexec/swift/pm/swiftpm-testing-helper")
  const products = join(repoRoot, packagePath, ".build/out/Products/Debug")
  const bundles = JSON.parse(
    execFileSync("swift", ["package", "dump-package", "--package-path", packagePath], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024
    })
  )
    .targets.filter((target) => target.type === "test")
    .map(({ name }) => join(products, `${name}.xctest/Contents/MacOS/${name}`))
  if (!existsSync(helper) || !bundles.every((bundle) => existsSync(bundle))) return fallback()
  const platform = join(
    execFileSync("xcode-select", ["-p"], { encoding: "utf8" }).trim(),
    "Platforms/MacOSX.platform/Developer"
  )
  // The environment `swift test` gives the helper.
  const environment = {
    ...process.env,
    DYLD_FRAMEWORK_PATH: `${platform}/Library/Frameworks:${platform}/Library/PrivateFrameworks`,
    DYLD_LIBRARY_PATH: `${products}:${platform}/usr/lib`
  }
  const pending = [...bundles]
  let status = 0
  const worker = async () => {
    while (pending.length > 0) {
      const bundle = pending.shift()
      const result = await runBundle(
        helper,
        bundle,
        [
          "--package-path",
          packagePath,
          "--skip-build",
          ...selection,
          "--testing-library",
          "swift-testing"
        ],
        environment
      )
      process.stdout.write(result.output)
      // No test-run summary at all means the helper never ran the bundle.
      if (result.code !== 0 || !/Test run with \d+ tests?/.test(result.output)) {
        console.error(`swift:test: ${bundle} failed or did not run (exit ${result.code})`)
        status = 1
      }
    }
  }
  await Promise.all(
    Array.from({ length: Math.max(2, Math.floor(availableParallelism() / 2)) }, worker)
  )
  return status
}

function runBundle(helper, bundle, args, env) {
  return new Promise((resolveBundle) => {
    let output = ""
    const child = spawn(helper, ["--test-bundle-path", bundle, ...args], { cwd: repoRoot, env })
    child.stdout.on("data", (chunk) => (output += chunk))
    child.stderr.on("data", (chunk) => (output += chunk))
    child.once("error", (error) => resolveBundle({ code: 1, output: `${error.message}\n` }))
    child.once("close", (code) => resolveBundle({ code, output }))
  })
}

/// Splits `--only=<path>` selections from the arguments forwarded to Swift.
export function parseSwiftTestArguments(argv) {
  const only = argv.filter((arg) => arg.startsWith("--only=")).map((arg) => arg.slice(7))
  for (const packagePath of only) {
    if (!swiftTestPackages.includes(packagePath)) {
      throw new Error(`Unknown Swift test package ${packagePath}`)
    }
  }
  return {
    args: argv.filter((arg) => !arg.startsWith("--only=")),
    packagePaths: only.length > 0 ? only : swiftTestPackages
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { args, packagePaths } = parseSwiftTestArguments(process.argv.slice(2))
  // CodevisorNet links the tunnel xcframework from the shared artifact cache.
  const net = spawnSync("node", ["scripts/net-artifact.mjs", "ensure-swift"], {
    cwd: repoRoot,
    stdio: "inherit"
  })
  if (net.status !== 0) process.exitCode = net.status ?? 1
  else {
    const store = developmentLayout(repoRoot).build.swiftArtifactStore
    for (const packagePath of packagePaths) {
      await prepareSwiftPackage({ repoRoot, packagePath, store })
    }
    process.exitCode = await runSwiftTests(args, {}, packagePaths)
  }
}
