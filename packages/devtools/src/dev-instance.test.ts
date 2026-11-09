import { mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import {
  migrateLegacyDevelopmentState,
  resolveDevelopmentInstance,
  sanitizeAmbientEnvironment
} from "./dev-instance.ts"
import { developmentLayout, localDevelopmentEnvironment } from "./dev-layout.ts"

const roots: Array<string> = []
afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })))
})

describe("sanitizeAmbientEnvironment", () => {
  it("keeps dev settings without inheriting app-hosted state", () => {
    const supplied: Record<string, string | undefined> = {
      CODEVISOR_APP_HOSTED: "1",
      CODEVISOR_APP_BUNDLE_PATH: "/Applications/Other Codevisor.app",
      HERDMAN_APP_HOSTED: "1",
      CODEVISOR_DEV_PORT: "45123",
      CODEVISOR_DEV_CONTAINER_DESKTOP: "1",
      CODEVISOR_SCREEN_SHARING_STATS_LOG: "/tmp/stats",
      PATH: "/usr/bin"
    }
    sanitizeAmbientEnvironment(supplied)
    const launch = localDevelopmentEnvironment(developmentLayout("/repo/worktree", {}), supplied)

    expect(launch.CODEVISOR_DEV_PORT).toBe("45123")
    expect(launch.CODEVISOR_DEV_CONTAINER_DESKTOP).toBe("1")
    expect(launch.CODEVISOR_SCREEN_SHARING_STATS_LOG).toBe("/tmp/stats")
    expect(launch.PATH).toBe("/usr/bin")
    expect(Object.hasOwn(launch, "CODEVISOR_APP_HOSTED")).toBe(false)
    expect(Object.hasOwn(launch, "CODEVISOR_APP_BUNDLE_PATH")).toBe(false)
    expect(Object.hasOwn(launch, "HERDMAN_APP_HOSTED")).toBe(false)
  })
})

describe("resolveDevelopmentInstance", () => {
  it("names, ports, and bundles each worktree's instance", async () => {
    const instance = await resolveDevelopmentInstance("/repo/worktrees/cayenne", {
      CODEVISOR_DEV_PORT: "52000",
      CODEVISOR_DEV_WWW_PORT: "62000"
    })

    expect(instance.port).toBe(52000)
    expect(instance.wwwPort).toBe(62000)
    expect(instance.cloudRemotePort).toBeGreaterThanOrEqual(52002)
    expect(instance.appName).toBe("Codevisor (cayenne)")
    expect(instance.instanceName).toMatch(/^cayenne-[0-9a-f]{10}$/)
    expect(instance.urlScheme).toBe(`codevisor-dev-${instance.instanceHash}`)
    expect(instance.appExecutable).toBe(
      join(
        instance.derivedDataPath,
        "Build/Products/Debug/Codevisor (cayenne).app/Contents/MacOS/Codevisor (cayenne)"
      )
    )
  })
})

describe("migrateLegacyDevelopmentState", () => {
  it("moves the old tmp data into the data directory when it holds a server database", async () => {
    const repoRoot = await mkdtemp(join(tmpdir(), "codevisor-instance-test-"))
    roots.push(repoRoot)
    const instance = await resolveDevelopmentInstance(repoRoot, {
      CODEVISOR_DEV_PORT: "52000",
      CODEVISOR_DEV_WWW_PORT: "62000"
    })
    const legacy = join(instance.tmpRoot, "codevisor")
    await mkdir(legacy, { recursive: true })
    await writeFile(join(legacy, "codevisor-server.sqlite"), "")

    await migrateLegacyDevelopmentState(instance, repoRoot)

    expect(await readdir(instance.dataDirectory)).toEqual(["codevisor-server.sqlite"])
    await expect(readdir(legacy)).rejects.toMatchObject({ code: "ENOENT" })
  })

  it("leaves existing data alone", async () => {
    const repoRoot = await mkdtemp(join(tmpdir(), "codevisor-instance-test-"))
    roots.push(repoRoot)
    const instance = await resolveDevelopmentInstance(repoRoot, {
      CODEVISOR_DEV_PORT: "52000",
      CODEVISOR_DEV_WWW_PORT: "62000"
    })
    await mkdir(instance.dataDirectory, { recursive: true })
    await writeFile(join(instance.dataDirectory, "current"), "")
    await mkdir(join(repoRoot, ".codevisor"), { recursive: true })

    await migrateLegacyDevelopmentState(instance, repoRoot)

    expect(await readdir(instance.dataDirectory)).toEqual(["current"])
  })
})
