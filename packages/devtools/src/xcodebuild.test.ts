import assert from "node:assert/strict"

import { test } from "vitest"

import { developmentLayout } from "./dev-layout.ts"
import {
  packageResolutionArguments,
  packageResolutionInputs,
  xcodebuildArguments
} from "./xcodebuild.ts"

test("xcodebuild builds pin worktree-local caches", () => {
  const layout = developmentLayout("/repo/codevisor", {})
  const xcodeArguments = xcodebuildArguments(layout, "macos", ["-scheme", "Codevisor", "build"])

  assert.deepEqual(xcodeArguments.slice(0, 8), [
    "-derivedDataPath",
    layout.build.macos.derivedData,
    "-clonedSourcePackagesDirPath",
    layout.build.macos.sourcePackages,
    "-packageCachePath",
    layout.build.packageCache,
    "-skipMacroValidation",
    "COMPILER_INDEX_STORE_ENABLE=NO"
  ])
  assert.deepEqual(xcodeArguments.slice(8), ["-scheme", "Codevisor", "build"])
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
  const list = ["-list", "-project", "apps/macos/Codevisor.xcodeproj"]
  assert.deepEqual(xcodebuildArguments(layout, "macos", list), list)
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
  assert.equal(packageResolutionArguments(["-scheme", "Codevisor", "build"]), undefined)
})

test("package resolution fingerprints the project's or workspace's pins", () => {
  assert.equal(
    packageResolutionInputs("/repo", ["-project", "apps/ios/Codevisor.xcodeproj"])[0],
    "/repo/apps/ios/Codevisor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  )
  assert.deepEqual(packageResolutionInputs("/repo", ["-workspace", "Codevisor.xcworkspace"]), [
    "/repo/Codevisor.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "/repo/packages/swift/Package.swift",
    "/repo/packages/swift/Package.resolved"
  ])
})
