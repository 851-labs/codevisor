import { execFileSync, spawn, spawnSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import { availableParallelism } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { developmentLayout } from "./dev-layout.mjs"
import { prepareSwiftPackage } from "./swift-artifacts.mjs"

export const mainSerialExecutorSuites = JSON.parse(
  readFileSync(
    new URL("../packages/swift/main-serial-executor-suites.json", import.meta.url),
    "utf8"
  )
)

export const mainSerialExecutorFilter = `(${mainSerialExecutorSuites.join("|")})/`

export const swiftTestingOnly = ["--disable-xctest"]

export const swiftTestPackages = ["packages/swift", "apps/screen-sharing-rig"]

const repoRoot = fileURLToPath(new URL("..", import.meta.url))

export async function runSwiftTests(
  args = [],
  { run = spawnSync, runBundles = runTestBundles } = {},
  packagePaths = swiftTestPackages
) {
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

function testBundlePaths(packagePath, products) {
  return JSON.parse(
    execFileSync("swift", ["package", "dump-package", "--package-path", packagePath], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024
    })
  )
    .targets.filter((target) => target.type === "test")
    .map(({ name }) => join(products, `${name}.xctest/Contents/MacOS/${name}`))
}

function testBundleEnvironment(products) {
  const platform = join(
    execFileSync("xcode-select", ["-p"], { encoding: "utf8" }).trim(),
    "Platforms/MacOSX.platform/Developer"
  )
  return {
    ...process.env,
    DYLD_FRAMEWORK_PATH: `${platform}/Library/Frameworks:${platform}/Library/PrivateFrameworks`,
    DYLD_LIBRARY_PATH: `${products}:${platform}/usr/lib`
  }
}

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
  const bundles = testBundlePaths(packagePath, products)
  if (!existsSync(helper) || !bundles.every((bundle) => existsSync(bundle))) return fallback()
  const environment = testBundleEnvironment(products)
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
      if (result.code !== 0 || !/Test run with \d+ tests?/.test(result.output)) {
        console.error(
          `swift:test: ${bundle} failed or did not run (exit ${result.code}${result.signal ? `, signal ${result.signal}` : ""})`
        )
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
    child.once("close", (code, signal) => resolveBundle({ code, output, signal }))
  })
}

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
