import { spawn } from "node:child_process"
import { mkdir } from "node:fs/promises"
import process from "node:process"

import { developmentLayout } from "./dev-layout.mjs"

export function xcodebuildArguments(layout, platform, arguments_) {
  const platformLayout = layout.build[platform]
  if (platformLayout === undefined || !["macos", "ios", "pixelbook"].includes(platform)) {
    throw new Error(`Unknown Xcode platform ${platform}`)
  }
  return [
    "-derivedDataPath",
    platformLayout.derivedData,
    "-clonedSourcePackagesDirPath",
    platformLayout.sourcePackages,
    "-packageCachePath",
    layout.build.packageCache,
    ...arguments_
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
