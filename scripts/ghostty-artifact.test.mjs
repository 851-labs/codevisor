import assert from "node:assert/strict"
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

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
