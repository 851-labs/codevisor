import { execFileSync, spawn, spawnSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import { availableParallelism } from "node:os"
import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { developmentLayout } from "../packages/devtools/src/dev-layout.ts"
import { prepareSwiftPackage } from "./swift-artifacts.mjs"

export const mainSerialExecutorSuites = JSON.parse(
  readFileSync(
    new URL("../packages/swift/main-serial-executor-suites.json", import.meta.url),
    "utf8"
  )
)

export const mainSerialExecutorFilter = `(${mainSerialExecutorSuites.join("|")})/`

export const hardwareCodecSuites = ["HardwareCodecTests"]

export const hardwareCodecFilter = `(${hardwareCodecSuites.join("|")})/`

export const skipHardwareCodecTests = "--skip-hardware-codec-tests"

export const swiftTestingOnly = ["--disable-xctest"]

const swiftPackagePath = "packages/swift"

export const bundleTimeLimitMs = 10 * 60_000

const repoRoot = fileURLToPath(new URL("..", import.meta.url))

export async function runSwiftTests(
  options = [],
  { run = spawnSync, runBundles = runTestBundles } = {}
) {
  const args = options.filter((arg) => arg !== skipHardwareCodecTests)
  const hardwareCodecSelection = args.length < options.length ? ["--skip", hardwareCodecFilter] : []
  for (const arg of args) {
    if (/^--(?:filter|skip|package-path|specifier)(?:=|$)/.test(arg) || arg === "-s") {
      throw new Error(`Test selection is managed by swift:test; cannot forward ${arg}`)
    }
  }
  const steps = [
    { swift: ["build", "--build-tests", "--package-path", swiftPackagePath] },
    {
      bundles: swiftPackagePath,
      selection: ["--skip", mainSerialExecutorFilter, ...hardwareCodecSelection]
    },
    {
      swift: ["test", "--package-path", swiftPackagePath, "--skip-build"],
      selection: ["--filter", mainSerialExecutorFilter, ...hardwareCodecSelection]
    }
  ]
  for (const step of steps) {
    const selected = [...(step.selection ?? []), ...swiftTestingOnly, ...args]
    let status
    if (step.bundles === undefined) {
      status = swiftStatus(
        run("swift", [...step.swift, ...selected], { cwd: repoRoot, stdio: "inherit" })
      )
    } else {
      status = await runBundles(step.bundles, selected, run)
    }
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
      if (result.timedOut) {
        console.error(
          `swift:test: ${bundle} ran past ${bundleTimeLimitMs / 60_000} min and was stopped`
        )
      }
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

export function runBundle(helper, bundle, args, env, timeLimitMs = bundleTimeLimitMs) {
  return new Promise((resolveBundle) => {
    let output = ""
    let timedOut = false
    const child = spawn(helper, ["--test-bundle-path", bundle, ...args], { cwd: repoRoot, env })
    const timer = setTimeout(() => {
      timedOut = true
      child.kill("SIGKILL")
    }, timeLimitMs)
    child.stdout.on("data", (chunk) => (output += chunk))
    child.stderr.on("data", (chunk) => (output += chunk))
    child.once("error", (error) => {
      clearTimeout(timer)
      resolveBundle({ code: 1, output: `${error.message}\n` })
    })
    child.once("close", (code, signal) => {
      clearTimeout(timer)
      resolveBundle({ code, output, signal, timedOut })
    })
  })
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const net = spawnSync("node", ["scripts/net-artifact.mjs", "ensure-swift"], {
    cwd: repoRoot,
    stdio: "inherit"
  })
  if (net.status !== 0) process.exitCode = net.status ?? 1
  else {
    const store = developmentLayout(repoRoot).build.swiftArtifactStore
    await prepareSwiftPackage({ repoRoot, packagePath: swiftPackagePath, store })
    process.exitCode = await runSwiftTests(process.argv.slice(2))
  }
}
