import { spawn } from "node:child_process"
import { mkdir } from "node:fs/promises"
import { join, resolve } from "node:path"
import process from "node:process"

import { developmentLayout } from "./dev-layout.mjs"
import { prepareSwiftArtifacts } from "./swift-artifacts.mjs"

// Operations that never resolve packages, so there is nothing to share.
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
  // Export and platform installation do not build a scheme. Xcode rejects
  // the build-specific cache flags for these standalone operations.
  if (arguments_.includes("-exportArchive") || arguments_.includes("-downloadPlatform")) {
    return [...arguments_]
  }
  // Package dependencies ship Swift macros (Composable Architecture and its
  // macro packages). Xcode gates unapproved macro plugins behind an
  // interactive prompt; command-line builds trust the pinned checkouts.
  return [
    "-derivedDataPath",
    platformLayout.derivedData,
    "-clonedSourcePackagesDirPath",
    platformLayout.sourcePackages,
    "-packageCachePath",
    layout.build.packageCache,
    "-skipMacroValidation",
    // Only an Xcode window reads an index store, and Xcode windows build into
    // their own XcodeDerivedData (xcode-derived-data.mjs). Scripted builds
    // writing one cost ~230 MB per platform per worktree for no reader.
    "COMPILER_INDEX_STORE_ENABLE=NO",
    ...arguments_
  ]
}

/// The -project/-workspace and -scheme arguments to resolve the packages an
/// xcodebuild invocation builds, or undefined when it does not build.
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

/// Files whose contents decide what a project resolves: its pinned versions
/// and the local CodevisorKit manifest, which declares the Sentry artifact.
export function packageResolutionInputs(repoRoot, resolutionArguments) {
  const valueOf = (flag) => {
    const index = resolutionArguments.indexOf(flag)
    return index === -1 ? undefined : resolutionArguments[index + 1]
  }
  const workspace = valueOf("-workspace")
  const pins =
    workspace === undefined
      ? join(resolve(repoRoot, valueOf("-project")), "project.xcworkspace")
      : resolve(repoRoot, workspace)
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

  // Resolve first and swap the unpacked binary artifacts for shared clones
  // before anything builds from them (swift-artifacts.mjs). Skipped, along
  // with the resolve, when the pins have not changed since the last run.
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

function waitForExit(child) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode })
  }
  return new Promise((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }))
  })
}
