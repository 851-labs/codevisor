import { spawn, spawnSync } from "node:child_process"
import { mkdir } from "node:fs/promises"
import { join, resolve as resolvePath } from "node:path"
import process from "node:process"

import { waitForExit } from "../packages/devtools/src/child-processes.ts"
import { developmentLayout } from "../packages/devtools/src/dev-layout.ts"
import { prepareSwiftArtifacts } from "./swift-artifacts.mjs"

const nonBuildingOperations = new Set([
  "-exportArchive",
  "-downloadPlatform",
  "-list",
  "-showBuildSettings",
  "-showdestinations",
  "-showsdks",
  "-version"
])

export function xcodebuildArguments(layout, platform, arguments_) {
  const platformLayout = layout.build[platform]
  if (platformLayout === undefined || !["macos", "ios", "pixelbook"].includes(platform)) {
    throw new Error(`Unknown Xcode platform ${platform}`)
  }
  if (arguments_.includes("-exportArchive") || arguments_.includes("-downloadPlatform")) {
    return [...arguments_]
  }
  return [
    "-derivedDataPath",
    platformLayout.derivedData,
    "-clonedSourcePackagesDirPath",
    platformLayout.sourcePackages,
    "-packageCachePath",
    layout.build.packageCache,
    "-skipMacroValidation",
    "COMPILER_INDEX_STORE_ENABLE=NO",
    ...arguments_
  ]
}

export function packageResolutionArguments(arguments_) {
  if (arguments_.some((argument) => nonBuildingOperations.has(argument))) return undefined
  const selected = []
  for (const flag of ["-project", "-workspace", "-scheme"]) {
    const index = arguments_.indexOf(flag)
    if (index !== -1 && index + 1 < arguments_.length) selected.push(flag, arguments_[index + 1])
  }
  if (!selected.includes("-project") && !selected.includes("-workspace")) return undefined
  return selected
}

export function packageResolutionInputs(repoRoot, resolutionArguments) {
  const valueOf = (flag) => {
    const index = resolutionArguments.indexOf(flag)
    return index === -1 ? undefined : resolutionArguments[index + 1]
  }
  const workspace = valueOf("-workspace")
  const pins =
    workspace === undefined
      ? join(resolvePath(repoRoot, valueOf("-project")), "project.xcworkspace")
      : resolvePath(repoRoot, workspace)
  return [
    join(pins, "xcshareddata/swiftpm/Package.resolved"),
    join(repoRoot, "packages/swift/Package.swift"),
    join(repoRoot, "packages/swift/Package.resolved")
  ]
}

export async function runXcodebuild(repoRoot, platform, arguments_, options = {}) {
  const layout = options.layout ?? developmentLayout(repoRoot, options.environment)
  const xcodeArguments = xcodebuildArguments(layout, platform, arguments_)
  const platformLayout = layout.build[platform]
  await Promise.all(
    [platformLayout.derivedData, platformLayout.sourcePackages, layout.build.packageCache].map(
      (directory) => mkdir(directory, { recursive: true })
    )
  )

  const resolution = packageResolutionArguments(arguments_)
  if (resolution !== undefined) {
    await prepareSwiftArtifacts({
      stateDirectory: platformLayout.sourcePackages,
      store: layout.build.swiftArtifactStore,
      inputs: packageResolutionInputs(repoRoot, resolution),
      resolve: () =>
        spawnXcodebuild(
          repoRoot,
          xcodebuildArguments(layout, platform, [...resolution, "-resolvePackageDependencies"]),
          options
        )
    })
    if (arguments_.includes("-resolvePackageDependencies")) return
  }
  await spawnXcodebuild(repoRoot, xcodeArguments, options)
}

async function spawnXcodebuild(repoRoot, xcodeArguments, options) {
  console.log(`\n$ xcodebuild ${xcodeArguments.join(" ")}`)
  const environment = options.environment ?? process.env
  const formatted = options.stdio === undefined && formatsForGitHub(environment)
  const child = spawn("xcodebuild", xcodeArguments, {
    cwd: repoRoot,
    env: environment,
    stdio: formatted ? ["inherit", "pipe", "pipe"] : (options.stdio ?? "inherit")
  })
  const formatter = formatted ? pipeThroughXcbeautify(child, environment) : undefined
  const result = await waitForExit(child)
  if (formatter !== undefined) await waitForExit(formatter)
  if (result.code !== 0) {
    throw new Error(
      `xcodebuild failed (${result.signal === null ? `code ${result.code ?? 1}` : `signal ${result.signal}`})`
    )
  }
}

function formatsForGitHub(environment) {
  return (
    environment.GITHUB_ACTIONS === "true" &&
    environment.CODEVISOR_XCBEAUTIFY !== "0" &&
    hasXcbeautify(environment)
  )
}

function hasXcbeautify(environment) {
  return spawnSync("xcbeautify", ["--version"], { env: environment, stdio: "ignore" }).status === 0
}

function pipeThroughXcbeautify(child, environment) {
  const formatter = spawn("xcbeautify", ["--renderer", "github-actions"], {
    env: environment,
    stdio: ["pipe", "inherit", "inherit"]
  })
  child.stdout.pipe(formatter.stdin, { end: false })
  child.stderr.pipe(formatter.stdin, { end: false })
  child.once("close", () => formatter.stdin.end())
  return formatter
}
