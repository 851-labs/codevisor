import assert from "node:assert/strict"
import { access, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import {
  developmentLayout,
  ensureBuildDirectories,
  IOS_DEVELOPMENT_BUNDLE_IDENTIFIER,
  iosDevelopmentBundleIdentifier,
  localDevelopmentEnvironment,
  remoteDevelopmentEnvironment
} from "./dev-layout.mjs"

test("development layout mirrors production roots inside tmp", () => {
  const root = "/repo/codevisor"
  const layout = developmentLayout(root, {})

  assert.equal(layout.local.worktrees, join(root, "tmp/codevisor"))
  assert.equal(layout.local.data, join(root, "tmp/.codevisor/data"))
  assert.equal(layout.local.logs, join(root, "tmp/.codevisor/logs"))
  assert.equal(layout.local.cache, join(root, "tmp/.codevisor/cache"))
  assert.equal(layout.remote.worktrees, join(root, "tmp/remote/codevisor"))
  assert.equal(layout.remote.data, join(root, "tmp/remote/.codevisor/data"))
  assert.equal(layout.remoteCloud.worktrees, join(root, "tmp/remote-cloud/codevisor"))
  assert.equal(layout.remoteCloud.data, join(root, "tmp/remote-cloud/.codevisor/data"))
  assert.equal(layout.build.macos.derivedData, join(root, "tmp/build/macos/DerivedData"))
  assert.equal(layout.build.ios.derivedData, join(root, "tmp/build/ios/DerivedData"))
  assert.equal(layout.build.bunCache, join(root, "tmp/build/bun-cache"))
  assert.equal(layout.build.nodeGyp, join(root, "tmp/build/node-gyp"))
  assert.equal(layout.wrangler, join(root, "tmp/.wrangler"))
  assert.equal(IOS_DEVELOPMENT_BUNDLE_IDENTIFIER, "com.851labs.Codevisor.Development.iOS")
})

test("iOS dev bundle identifiers are stable and isolated by worktree", () => {
  const cayenne = iosDevelopmentBundleIdentifier("/repo/worktrees/cayenne")

  assert.match(cayenne, /^com\.851labs\.Codevisor\.Development\.iOS\.[0-9a-f]{10}$/)
  assert.equal(cayenne, iosDevelopmentBundleIdentifier("/repo/worktrees/cayenne"))
  assert.notEqual(cayenne, iosDevelopmentBundleIdentifier("/repo/worktrees/quark"))
})

test("build-only setup does not create runtime state roots", async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-layout-test-"))
  try {
    const layout = developmentLayout(root, {})
    await ensureBuildDirectories(layout)

    await access(layout.build.bunCache)
    await access(layout.runtime.temp)
    await assert.rejects(access(layout.local.data), { code: "ENOENT" })
    await assert.rejects(access(layout.remote.data), { code: "ENOENT" })
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("development environments point services at their own production-shaped roots", () => {
  const layout = developmentLayout("/repo/codevisor", {})
  const local = localDevelopmentEnvironment(layout, { PATH: "/bin" })
  const remote = remoteDevelopmentEnvironment(layout, { PATH: "/bin" })

  assert.equal(local.CODEVISOR_DATA_DIR, layout.local.data)
  assert.equal(local.CODEVISOR_LOGS_DIR, layout.local.logs)
  assert.equal(local.CODEVISOR_REPOS_ROOT, layout.local.repos)
  assert.equal(local.CODEVISOR_WORKTREES_ROOT, layout.local.worktrees)
  assert.equal(local.TMPDIR, layout.runtime.temp)
  assert.equal(local.BUN_INSTALL_CACHE_DIR, layout.build.bunCache)
  assert.equal(local.npm_config_devdir, layout.build.nodeGyp)
  assert.equal(remote.CODEVISOR_DATA_DIR, layout.remote.data)
  assert.equal(remote.CODEVISOR_WORKTREES_ROOT, layout.remote.worktrees)
  assert.equal(remote.PATH, "/bin")

  const remoteCloud = remoteDevelopmentEnvironment(layout, { PATH: "/bin" }, layout.remoteCloud)
  assert.equal(remoteCloud.CODEVISOR_DATA_DIR, layout.remoteCloud.data)
  assert.equal(remoteCloud.CODEVISOR_WORKTREES_ROOT, layout.remoteCloud.worktrees)
})
