import { join } from "node:path"

export function requestsMacOSBuildReuse(arguments_) {
  const requested = arguments_.includes("--reuse-macos-build")
  if (requested && !arguments_.includes("--no-ios")) {
    throw new Error("--reuse-macos-build is supported only by dev:macos.")
  }
  return requested
}

/// Reusing a granted ad-hoc app must never fall back to a rebuild: that
/// would change its signing requirement while appearing to preserve it.
export async function verifyReusableMacOSApp({
  appBundle,
  bundleIdentifier,
  executableName,
  capture,
  run
}) {
  const plist = join(appBundle, "Contents", "Info.plist")
  const metadata = JSON.parse(
    await capture("/usr/bin/plutil", ["-convert", "json", "-o", "-", plist])
  )
  for (const [key, expected] of [
    ["CFBundleIdentifier", bundleIdentifier],
    ["CFBundleExecutable", executableName]
  ]) {
    const actual = metadata[key]
    if (actual !== expected) {
      throw new Error(`Cannot reuse macOS build: ${key} is ${actual}, expected ${expected}.`)
    }
  }
  await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appBundle])
}
