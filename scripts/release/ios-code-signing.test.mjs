import assert from "node:assert/strict"
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import { embeddedCodePaths } from "./ios-code-signing.mjs"

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
