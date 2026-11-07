import { access, mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises"
import { homedir, tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import {
  developmentLayout,
  discardLegacyBunCache,
  ensureBuildDirectories,
  ensureDevelopmentDirectories,
  IOS_DEVELOPMENT_BUNDLE_IDENTIFIER,
  iosDevelopmentBundleIdentifier,
  localDevelopmentEnvironment,
  remoteDevelopmentEnvironment
} from "./dev-layout.ts"

const roots: Array<string> = []
const scratch = async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-layout-test-"))
  roots.push(root)
  return root
}
afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })))
})

describe("developmentLayout", () => {
  it("mirrors production roots inside tmp", () => {
    const root = "/repo/codevisor"
    const layout = developmentLayout(root, {})

    expect(layout.local.worktrees).toBe(join(root, "tmp/codevisor"))
    expect(layout.local.data).toBe(join(root, "tmp/.codevisor/data"))
    expect(layout.local.logs).toBe(join(root, "tmp/.codevisor/logs"))
    expect(layout.local.cache).toBe(join(root, "tmp/.codevisor/cache"))
    expect(layout.remoteCloud.worktrees).toBe(join(root, "tmp/remote-cloud/codevisor"))
    expect(layout.remoteCloud.data).toBe(join(root, "tmp/remote-cloud/.codevisor/data"))
    expect(layout.build.macos.derivedData).toBe(join(root, "tmp/build/macos/DerivedData"))
    expect(layout.build.ios.derivedData).toBe(join(root, "tmp/build/ios/DerivedData"))
    expect(layout.build.bunCache).toBe(
      join(homedir(), ".codevisor-development/artifacts/bun-cache")
    )
    expect(layout.build.nodeGyp).toBe(join(root, "tmp/build/node-gyp"))
    expect(layout.wrangler).toBe(join(root, "tmp/.wrangler"))
    expect(IOS_DEVELOPMENT_BUNDLE_IDENTIFIER).toBe("com.851labs.Codevisor.Development.iOS")
  })

  it("lets the environment move service roots", () => {
    const layout = developmentLayout("/repo", {
      CODEVISOR_DEV_DATA_DIR: "/data",
      CODEVISOR_WORKTREES_ROOT: "/worktrees"
    })

    expect(layout.local.data).toBe("/data")
    expect(layout.local.worktrees).toBe("/worktrees")
  })
})

describe("iosDevelopmentBundleIdentifier", () => {
  it("is stable and isolated by worktree", () => {
    const cayenne = iosDevelopmentBundleIdentifier("/repo/worktrees/cayenne")

    expect(cayenne).toMatch(/^com\.851labs\.Codevisor\.Development\.iOS\.[0-9a-f]{10}$/)
    expect(iosDevelopmentBundleIdentifier("/repo/worktrees/cayenne")).toBe(cayenne)
    expect(iosDevelopmentBundleIdentifier("/repo/worktrees/quark")).not.toBe(cayenne)
  })
})

describe("directory setup", () => {
  it("creates build roots without runtime state for build-only setup", async () => {
    const root = await scratch()
    const layout = developmentLayout(root, { CODEVISOR_BUN_CACHE: join(root, "bun-cache") })
    await ensureBuildDirectories(layout)

    await access(layout.build.bunCache)
    await access(layout.runtime.temp)
    await expect(access(layout.local.data)).rejects.toMatchObject({ code: "ENOENT" })
  })

  it("creates every service root for a full development setup", async () => {
    const root = await scratch()
    const layout = developmentLayout(root, { CODEVISOR_BUN_CACHE: join(root, "bun-cache") })
    await ensureDevelopmentDirectories(layout)

    await access(layout.local.data)
    await access(layout.remoteCloud.worktrees)
    await access(layout.wrangler)
  })
})

describe("development environments", () => {
  it("point services at their own production-shaped roots", () => {
    const layout = developmentLayout("/repo/codevisor", {})
    const local = localDevelopmentEnvironment(layout, { PATH: "/bin" })
    const remote = remoteDevelopmentEnvironment(layout, { PATH: "/bin" })

    expect(local.CODEVISOR_DATA_DIR).toBe(layout.local.data)
    expect(local.CODEVISOR_LOGS_DIR).toBe(layout.local.logs)
    expect(local.CODEVISOR_REPOS_ROOT).toBe(layout.local.repos)
    expect(local.CODEVISOR_WORKTREES_ROOT).toBe(layout.local.worktrees)
    expect(local.TMPDIR).toBe(layout.runtime.temp)
    expect(local.BUN_INSTALL_CACHE_DIR).toBe(layout.build.bunCache)
    expect(local.npm_config_devdir).toBe(layout.build.nodeGyp)
    expect(remote.CODEVISOR_DATA_DIR).toBe(layout.remoteCloud.data)
    expect(remote.CODEVISOR_WORKTREES_ROOT).toBe(layout.remoteCloud.worktrees)
    expect(remote.PATH).toBe("/bin")
  })
})

describe("discardLegacyBunCache", () => {
  it("moves a worktree's pre-sharing bun cache aside for background deletion once", async () => {
    const root = await scratch()
    const layout = developmentLayout(root, { CODEVISOR_BUN_CACHE: join(root, "shared-bun-cache") })
    await mkdir(layout.build.legacyBunCache, { recursive: true })
    await writeFile(join(layout.build.legacyBunCache, "package.tgz"), "")
    const removed: Array<string> = []

    expect(await discardLegacyBunCache(layout, (path) => removed.push(path))).toBe(true)
    expect(await discardLegacyBunCache(layout, (path) => removed.push(path))).toBe(false)

    await expect(access(layout.build.legacyBunCache)).rejects.toMatchObject({ code: "ENOENT" })
    expect(removed).toHaveLength(1)
    expect(await readdir(removed[0] ?? "")).toEqual(["package.tgz"])
  })
})
