import { join } from "node:path"

import type { CaptureCommand, RunCommand } from "./dev-host-tools.ts"

export function requestsMacOSBuildReuse(arguments_: readonly string[]): boolean {
  const requested = arguments_.includes("--reuse-macos-build")
  if (requested && !arguments_.includes("--no-ios")) {
    throw new Error("--reuse-macos-build is supported only by dev:macos.")
  }
  return requested
}

export interface ReusableMacOSAppOptions {
  appBundle: string
  bundleIdentifier: string
  executableName: string
  capture: CaptureCommand
  run: RunCommand
}

/// Reusing a granted ad-hoc app must never fall back to a rebuild: that
/// would change its signing requirement while appearing to preserve it.
export async function verifyReusableMacOSApp({
  appBundle,
  bundleIdentifier,
  executableName,
  capture,
  run
}: ReusableMacOSAppOptions): Promise<void> {
  const plist = join(appBundle, "Contents", "Info.plist")
  const metadata: Record<string, unknown> = JSON.parse(
    await capture("/usr/bin/plutil", ["-convert", "json", "-o", "-", plist])
  )
  for (const [key, expected] of [
    ["CFBundleIdentifier", bundleIdentifier],
    ["CFBundleExecutable", executableName]
  ] as const) {
    const actual = metadata[key]
    if (actual !== expected) {
      throw new Error(`Cannot reuse macOS build: ${key} is ${actual}, expected ${expected}.`)
    }
  }
  await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appBundle])
}
