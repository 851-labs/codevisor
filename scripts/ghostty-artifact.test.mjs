import assert from "node:assert/strict"
import { execFile } from "node:child_process"
import { cp, mkdtemp, mkdir, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { promisify } from "node:util"

const execFileAsync = promisify(execFile)
const buildGhosttyScript = new URL("../apps/macos/scripts/build-ghostty.sh", import.meta.url)

import {
  GHOSTTY_SLICES,
  ghosttyArtifactsRoot,
  ghosttyCachedFramework,
  validFramework
} from "./ghostty-artifact.mjs"

test("the artifacts root honors CODEVISOR_GHOSTTY_ARTIFACTS_ROOT", () => {
  const root = ghosttyArtifactsRoot({ CODEVISOR_GHOSTTY_ARTIFACTS_ROOT: "/shared/ghostty" })
  assert.equal(root, "/shared/ghostty")
  assert.equal(
    ghosttyCachedFramework(root, "stamp"),
    "/shared/ghostty/stamp/GhosttyKit.xcframework"
  )
})

test("Ghostty build stamp is independent of the checkout path", async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-ghostty-stamp-test-"))
  try {
    const stamps = []
    for (const checkout of ["first", "nested/second"]) {
      const macosRoot = join(root, checkout, "apps/macos")
      const script = join(macosRoot, "scripts/build-ghostty.sh")
      await mkdir(join(macosRoot, "scripts"), { recursive: true })
      await cp(buildGhosttyScript, script)
      const { stdout } = await execFileAsync("/bin/bash", [script, "--print-stamp"])
      stamps.push(stdout.trim())
    }

    assert.equal(stamps[0], stamps[1])
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("Ghostty framework validation requires the expected stamp and structure", async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-ghostty-test-"))
  const framework = join(root, "GhosttyKit.xcframework")
  try {
    for (const slice of GHOSTTY_SLICES) {
      await mkdir(join(framework, slice, "Headers/GhosttyKit"), { recursive: true })
      await writeFile(join(framework, slice, "Headers/GhosttyKit/ghostty.h"), "header")
      await writeFile(join(framework, slice, "Headers/GhosttyKit/module.modulemap"), "module")
      await writeFile(join(framework, slice, "ghostty-internal.a"), "archive")
    }
    await writeFile(join(framework, "Info.plist"), "plist")
    await writeFile(join(framework, ".codevisor-stamp"), "current\n")

    assert.equal(await validFramework(framework, "current"), true)
    assert.equal(await validFramework(framework, "stale"), false)
    // Without its module map, Swift can't import the slice.
    await rm(join(framework, "ios-arm64/Headers/GhosttyKit/module.modulemap"))
    assert.equal(await validFramework(framework, "current"), false)
    await writeFile(join(framework, "ios-arm64/Headers/GhosttyKit/module.modulemap"), "module")
    assert.equal(await validFramework(framework, "current"), true)
    // A macOS-only framework (the iOS app links the other slices) is incomplete.
    await rm(join(framework, "ios-arm64"), { recursive: true })
    assert.equal(await validFramework(framework, "current"), false)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
