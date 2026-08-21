import assert from "node:assert/strict"
import { execFile } from "node:child_process"
import { cp, mkdtemp, mkdir, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { promisify } from "node:util"

const execFileAsync = promisify(execFile)
const buildGhosttyScript = new URL("../apps/macos/scripts/build-ghostty.sh", import.meta.url)
const ghosttyPatch = new URL(
  "../apps/macos/patches/ghostty-libcpp-availability.patch",
  import.meta.url
)

import {
  ghosttyArtifactsRoot,
  ghosttyCachedFramework,
  validFramework
} from "./ghostty-artifact.mjs"

test("shared Ghostty path is deterministic", () => {
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
      await mkdir(join(macosRoot, "patches"), { recursive: true })
      await cp(buildGhosttyScript, script)
      await cp(ghosttyPatch, join(macosRoot, "patches/ghostty-libcpp-availability.patch"))
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
    await mkdir(join(framework, "macos-arm64_x86_64/Headers"), { recursive: true })
    await writeFile(join(framework, ".codevisor-stamp"), "current\n")
    await writeFile(join(framework, "Info.plist"), "plist")
    await writeFile(join(framework, "macos-arm64_x86_64/Headers/ghostty.h"), "header")
    await writeFile(join(framework, "macos-arm64_x86_64/ghostty-internal.a"), "archive")

    assert.equal(await validFramework(framework, "current"), true)
    assert.equal(await validFramework(framework, "stale"), false)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
