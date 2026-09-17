import { spawn } from "node:child_process"
import type { ChildProcess, SpawnOptions } from "node:child_process"
import { mkdir } from "node:fs/promises"
import process from "node:process"

import type { DevelopmentDerivedDataPaths, DevelopmentLayout } from "./dev-layout.ts"
import { developmentLayout } from "./dev-layout.ts"

/// The Xcode platforms with worktree-local build caches in the development
/// layout. Anything else is rejected before xcodebuild starts.
export type XcodePlatform = "macos" | "ios" | "pixelbook"

export interface XcodebuildOptions {
  layout?: DevelopmentLayout
  environment?: NodeJS.ProcessEnv
  stdio?: SpawnOptions["stdio"]
}

export interface XcodebuildExit {
  code: number | null
  signal: NodeJS.Signals | null
}

export function xcodebuildArguments(
  layout: DevelopmentLayout,
  platform: XcodePlatform,
  arguments_: readonly string[]
): string[] {
  // Annotated as possibly absent because callers reach this function with
  // unvalidated platform names (release scripts, tests).
  const platformLayout: DevelopmentDerivedDataPaths | undefined = layout.build[platform]
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
    ...arguments_
  ]
}

export async function runXcodebuild(
  repoRoot: string,
  platform: XcodePlatform,
  arguments_: readonly string[],
  options: XcodebuildOptions = {}
): Promise<void> {
  const layout = options.layout ?? developmentLayout(repoRoot, options.environment)
  const xcodeArguments = xcodebuildArguments(layout, platform, arguments_)
  const platformLayout = layout.build[platform]
  await Promise.all(
    [platformLayout.derivedData, platformLayout.sourcePackages, layout.build.packageCache].map(
      (directory) => mkdir(directory, { recursive: true })
    )
  )

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

function waitForExit(child: ChildProcess): Promise<XcodebuildExit> {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode })
  }
  return new Promise((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }))
  })
}
