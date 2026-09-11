import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { copyFile, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import { embeddedCodePaths, prepareEmbeddedCode } from "./ios-code-signing.mjs"

test("signature checks cover embedded code inside out without following symlinks or signing resources", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-signing-"))
  t.after(() => rm(root, { recursive: true, force: true }))
  const app = join(root, "Codevisor.app")
  const extension = join(app, "PlugIns/Share.appex")
  const framework = join(extension, "Frameworks/SDK.framework")
  const library = join(app, "Frameworks/libswiftExample.dylib")
  const resources = join(app, "SDKResources.bundle")
  await mkdir(framework, { recursive: true })
  await mkdir(join(app, "Frameworks"), { recursive: true })
  await mkdir(resources)
  await writeFile(library, "fixture")
  await writeFile(join(resources, "PrivacyInfo.xcprivacy"), "fixture")
  await symlink(app, join(framework, "cycle"))
  await symlink(framework, join(app, "Frameworks/Alias.framework"))

  const paths = await embeddedCodePaths(app)
  assert.deepEqual(new Set(paths), new Set([framework, extension, library]))
  assert.ok(paths.indexOf(framework) < paths.indexOf(extension))
})

// codesign is a macOS boundary; the release itself also runs on macOS.
test(
  "archive preparation attaches Apple sign-in before distribution export",
  { skip: process.platform !== "darwin" },
  async (t) => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-entitlements-"))
    t.after(() => rm(root, { recursive: true, force: true }))
    const app = join(root, "Fixture.app")
    await mkdir(join(app, "Contents/MacOS"), { recursive: true })
    const executable = join(app, "Contents/MacOS/Fixture")
    await copyFile("/usr/bin/true", executable)
    execFileSync("codesign", ["--remove-signature", executable])
    const plist = (value) =>
      execFileSync("plutil", ["-convert", "xml1", "-o", "-", "-"], { input: JSON.stringify(value) })
    await writeFile(
      join(app, "Contents/Info.plist"),
      plist({
        CFBundleIdentifier: "com.example.codevisor.signing-test",
        CFBundleExecutable: "Fixture",
        CFBundlePackageType: "APPL"
      })
    )
    const entitlements = join(root, "Fixture.entitlements")
    const required = { "com.apple.developer.applesignin": ["Default"] }
    await writeFile(entitlements, plist(required))
    await prepareEmbeddedCode(app, entitlements)
    execFileSync("codesign", ["--verify", "--strict", app])
    const actual = execFileSync("codesign", ["--display", "--entitlements", "-", "--xml", app])
    assert.deepEqual(
      JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", "-"], { input: actual })),
      required
    )
  }
)
