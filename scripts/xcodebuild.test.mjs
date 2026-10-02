import assert from "node:assert/strict"
import test from "node:test"

import { developmentLayout } from "./dev-layout.mjs"
import { packageResolutionArguments, xcodebuildArguments } from "./xcodebuild.mjs"

test("xcodebuild builds pin worktree-local caches", () => {
  const layout = developmentLayout("/repo/codevisor", {})
  const arguments_ = xcodebuildArguments(layout, "macos", ["-scheme", "Codevisor", "build"])

  assert.deepEqual(arguments_.slice(0, 8), [
    "-derivedDataPath",
    layout.build.macos.derivedData,
    "-clonedSourcePackagesDirPath",
    layout.build.macos.sourcePackages,
    "-packageCachePath",
    layout.build.packageCache,
    "-skipMacroValidation",
    "COMPILER_INDEX_STORE_ENABLE=NO"
  ])
  assert.deepEqual(arguments_.slice(8), ["-scheme", "Codevisor", "build"])
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
  assert.equal(packageResolutionArguments(exportArguments), undefined)
  assert.deepEqual(xcodebuildArguments(layout, "ios", ["-downloadPlatform", "iOS"]), [
    "-downloadPlatform",
    "iOS"
  ])
})

test("xcodebuild arguments reject unknown platforms", () => {
  const layout = developmentLayout("/repo/codevisor", {})
  assert.throws(() => xcodebuildArguments(layout, "watchos", []), /Unknown Xcode platform/)
})

test("builds resolve the packages of the project and scheme they build", () => {
  const project = ["-project", "apps/ios/Codevisor.xcodeproj", "-scheme", "Codevisor"]

  assert.deepEqual(
    packageResolutionArguments([...project, "-configuration", "Debug", "build"]),
    project
  )
  assert.deepEqual(packageResolutionArguments([...project, "-resolvePackageDependencies"]), project)
  assert.equal(packageResolutionArguments([...project, "-showBuildSettings"]), undefined)
})
