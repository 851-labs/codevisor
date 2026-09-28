import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { mkdtemp, mkdir, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import { ensureXcodeDerivedDataSettings } from "./xcode-derived-data.mjs"

function read(path, key) {
  return execFileSync("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", path], {
    encoding: "utf8"
  }).trim()
}

test(
  "points each present project's Xcode DerivedData into the worktree and keeps other user settings",
  { skip: process.platform !== "darwin" },
  async (t) => {
    const root = await mkdtemp(join(tmpdir(), "xcode-derived-data-"))
    t.after(() => rm(root, { recursive: true, force: true }))
    await mkdir(join(root, "apps/ios/Codevisor.xcodeproj"), { recursive: true })
    const macosSettings = join(
      root,
      "apps/macos/Codevisor.xcodeproj/project.xcworkspace/xcuserdata/dev.xcuserdatad/WorkspaceSettings.xcsettings"
    )
    await mkdir(join(macosSettings, ".."), { recursive: true })
    execFileSync("/usr/bin/plutil", ["-create", "xml1", macosSettings])
    execFileSync("/usr/bin/plutil", [
      "-insert",
      "ShowSharedSchemesAutomaticallyEnabled",
      "-bool",
      "YES",
      macosSettings
    ])
    execFileSync("/usr/bin/plutil", [
      "-insert",
      "DerivedDataLocationStyle",
      "-string",
      "Default",
      macosSettings
    ])

    const written = await ensureXcodeDerivedDataSettings(root, "dev")

    // PixelBook is absent from this checkout, so nothing is created for it.
    assert.equal(written.length, 2)
    const iosSettings = written.find((path) => path.includes("apps/ios/"))
    assert.equal(read(iosSettings, "DerivedDataLocationStyle"), "WorkspaceRelativePath")
    assert.equal(
      read(iosSettings, "DerivedDataCustomLocation"),
      "../../tmp/build/ios/XcodeDerivedData"
    )
    assert.equal(read(macosSettings, "DerivedDataLocationStyle"), "WorkspaceRelativePath")
    assert.equal(
      read(macosSettings, "DerivedDataCustomLocation"),
      "../../tmp/build/macos/XcodeDerivedData"
    )
    assert.equal(read(macosSettings, "ShowSharedSchemesAutomaticallyEnabled"), "true")
  }
)
