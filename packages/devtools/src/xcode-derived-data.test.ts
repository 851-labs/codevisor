import { execFileSync } from "node:child_process"
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { ensureXcodeDerivedDataSettings, xcodeDerivedDataLocation } from "./xcode-derived-data.ts"

const cleanups: Array<() => Promise<unknown>> = []
afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()))
})

async function checkout() {
  const repoRoot = await mkdtemp(join(tmpdir(), "codevisor-derived-data-"))
  cleanups.push(() => rm(repoRoot, { recursive: true, force: true }))
  await mkdir(join(repoRoot, "apps/ios/Codevisor.xcodeproj"), { recursive: true })
  return repoRoot
}

const settings = (repoRoot: string) =>
  join(
    repoRoot,
    "apps/ios/Codevisor.xcodeproj/project.xcworkspace/xcuserdata/me.xcuserdatad/WorkspaceSettings.xcsettings"
  )

describe("ensureXcodeDerivedDataSettings", () => {
  it("points each present project's DerivedData into the worktree", async () => {
    const repoRoot = await checkout()

    expect(await ensureXcodeDerivedDataSettings(repoRoot, "me", "darwin")).toEqual([
      settings(repoRoot)
    ])
    expect(await readFile(settings(repoRoot), "utf8")).toContain(
      `<string>${xcodeDerivedDataLocation("ios")}</string>`
    )
    expect(await ensureXcodeDerivedDataSettings(repoRoot, "me", "linux")).toEqual([])
  })

  it.skipIf(process.platform !== "darwin")(
    "updates existing settings without discarding the user's other keys",
    async () => {
      const repoRoot = await checkout()
      await mkdir(join(settings(repoRoot), ".."), { recursive: true })
      await writeFile(
        settings(repoRoot),
        '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>BuildSystemType</key><string>Original</string><key>DerivedDataLocationStyle</key><string>Default</string></dict></plist>\n'
      )

      await ensureXcodeDerivedDataSettings(repoRoot, "me")

      const values = execFileSync(
        "/usr/bin/plutil",
        ["-convert", "json", "-o", "-", settings(repoRoot)],
        { encoding: "utf8" }
      )
      expect(JSON.parse(values)).toEqual({
        BuildSystemType: "Original",
        DerivedDataLocationStyle: "WorkspaceRelativePath",
        DerivedDataCustomLocation: xcodeDerivedDataLocation("ios")
      })
    }
  )
})
