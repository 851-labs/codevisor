import { spawn } from "node:child_process"
import { mkdir } from "node:fs/promises"
import { join, resolve as resolvePath } from "node:path"
import process from "node:process"

import { developmentLayout } from "./dev-layout.mjs"
import { waitForExit } from "./dev-shared.mjs"
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
  const child = spawn("xcodebuild", xcodeArguments, {
    cwd: repoRoot,
    env: options.environment ?? process.env,
    stdio: options.stdio ?? "inherit"
  })
  const result = await waitForExit(child)
  if (result.code !== 0) {
    throw new Error(
      `xcodebuild failed (${result.signal === null ? `code ${result.code ?? 1}` : `signal ${result.signal}`})`
    )
  }
}
