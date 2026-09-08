import assert from "node:assert/strict"
import test from "node:test"

import { developmentLayout } from "./dev-layout.mjs"
import { xcodebuildArguments } from "./xcodebuild.mjs"

test("xcodebuild builds pin worktree-local caches", () => {
  const layout = developmentLayout("/repo/codevisor", {})
  const arguments_ = xcodebuildArguments(layout, "macos", ["-scheme", "Codevisor", "build"])

  assert.deepEqual(arguments_.slice(0, 6), [
    "-derivedDataPath",
    layout.build.macos.derivedData,
    "-clonedSourcePackagesDirPath",
    layout.build.macos.sourcePackages,
    "-packageCachePath",
    layout.build.packageCache
  ])
  assert.deepEqual(arguments_.slice(6), ["-scheme", "Codevisor", "build"])
})

test("standalone Xcode operations omit incompatible build flags", () => {
  const layout = developmentLayout("/repo/codevisor", {})
  const exportArguments = [
    "-exportArchive",
    "-archivePath",
    "/repo/codevisor/tmp/build/ios/Codevisor.xcarchive",
    "-exportOptionsPlist",
    "/repo/codevisor/tmp/build/ios/ExportOptions.plist",
    "-exportPath",
    "/repo/codevisor/tmp/build/ios/export"
  ]

  assert.deepEqual(xcodebuildArguments(layout, "ios", exportArguments), exportArguments)
  assert.deepEqual(xcodebuildArguments(layout, "ios", ["-downloadPlatform", "iOS"]), [
    "-downloadPlatform",
    "iOS"
  ])
})

test("xcodebuild arguments reject unknown platforms", () => {
  const layout = developmentLayout("/repo/codevisor", {})
  assert.throws(() => xcodebuildArguments(layout, "watchos", []), /Unknown Xcode platform/)
})
