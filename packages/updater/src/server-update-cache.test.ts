import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import {
  defaultServerUpdateCacheFs,
  explainDiskFull,
  requiredFreeBytes,
  serverUpdateCache,
  type ServerUpdateCacheFs
} from "./server-update-cache.js"

const gigabyte = 1024 ** 3

const makeHome = (): string => {
  const home = mkdtempSync(join(tmpdir(), "codevisor-update-cache-"))
  onTestFinished(() => rmSync(home, { recursive: true, force: true }))
  return home
}

const writeRuntime = (root: string): void => {
  mkdirSync(join(root, "bin"), { recursive: true })
  writeFileSync(join(root, "main.js"), "")
  writeFileSync(join(root, "bin", "node"), "")
}

const seedInstall = (home: string, versions: ReadonlyArray<string>): string => {
  const dataDir = join(home, ".codevisor", "data")
  for (const version of versions) {
    writeRuntime(join(dataDir, "server-updates", version, "runtime"))
    writeFileSync(join(dataDir, "server-updates", version, "codevisor-server.tar.gz"), "")
  }
  writeRuntime(join(home, ".codevisor", "server"))
  writeRuntime(join(home, ".codevisor", "server.next"))
  return dataDir
}

const cacheEntries = (dataDir: string): ReadonlyArray<string> =>
  readdirSync(join(dataDir, "server-updates")).toSorted()

const runtimeEntrypoint = (dataDir: string, version: string): string =>
  join(dataDir, "server-updates", version, "runtime", "main.js")

const fakeFs = (overrides: Partial<ServerUpdateCacheFs>): ServerUpdateCacheFs => ({
  list: async () => [],
  remove: async () => undefined,
  resolve: async (path) => path,
  freeBytes: async () => 0,
  ...overrides
})

const failure = (code: string): Error => Object.assign(new Error(code), { code })

describe("serverUpdateCache prune", () => {
  it("removes old versions and partial downloads but keeps the update being applied", async () => {
    const home = makeHome()
    const dataDir = seedInstall(home, ["0.1.100", "0.1.101", "0.1.102"])
    writeFileSync(join(dataDir, "server-updates", "partial.tar.gz"), "")
    mkdirSync(join(dataDir, "server-updates", ".download-tmp"))
    const cache = serverUpdateCache({
      dataDir,
      runningEntrypoint: join(home, ".codevisor", "server", "main.js")
    })

    const prune = await cache.prune(["0.1.102"])

    expect(prune).toEqual({
      kept: ["0.1.102"],
      removed: [".download-tmp", "0.1.100", "0.1.101", "partial.tar.gz"],
      failures: []
    })
    expect(cacheEntries(dataDir)).toEqual(["0.1.102"])
    expect(existsSync(join(home, ".codevisor", "server", "main.js"))).toBe(true)
    expect(existsSync(join(home, ".codevisor", "server.next", "main.js"))).toBe(true)
  })

  it("keeps the version the server is running from, even through a symlinked path", async () => {
    const home = makeHome()
    const dataDir = seedInstall(home, ["0.1.100", "0.1.101", "0.1.102"])
    symlinkSync(join(home, ".codevisor"), join(home, "linked"))
    const cache = serverUpdateCache({
      dataDir,
      runningEntrypoint: runtimeEntrypoint(join(home, "linked", "data"), "0.1.101")
    })

    const prune = await cache.prune([])

    expect(prune.kept).toEqual(["0.1.101"])
    expect(cacheEntries(dataDir)).toEqual(["0.1.101"])
    expect(existsSync(runtimeEntrypoint(dataDir, "0.1.101"))).toBe(true)
  })

  it("keeps a version directory that links to the running runtime", async () => {
    const home = makeHome()
    const dataDir = seedInstall(home, ["0.1.100"])
    writeRuntime(join(home, "elsewhere", "runtime"))
    symlinkSync(join(home, "elsewhere"), join(dataDir, "server-updates", "0.1.101"))
    const cache = serverUpdateCache({
      dataDir,
      runningEntrypoint: runtimeEntrypoint(dataDir, "0.1.101")
    })

    const prune = await cache.prune([])

    expect(prune).toEqual({ kept: ["0.1.101"], removed: ["0.1.100"], failures: [] })
    expect(existsSync(runtimeEntrypoint(dataDir, "0.1.101"))).toBe(true)
  })

  it("protects nothing for an entrypoint outside a version directory", async () => {
    const home = makeHome()
    const dataDir = seedInstall(home, ["0.1.100"])
    const entrypoints = [
      undefined,
      "",
      join(dataDir, "server-updates"),
      join(dataDir, "main.js"),
      join(home, "missing", "main.js")
    ]

    for (const runningEntrypoint of entrypoints) {
      writeRuntime(join(dataDir, "server-updates", "0.1.100", "runtime"))
      const prune = await serverUpdateCache({ dataDir, runningEntrypoint }).prune([])
      expect(prune.removed).toEqual(["0.1.100"])
    }
  })

  it("returns an empty result when no update was ever downloaded", async () => {
    const dataDir = join(makeHome(), "data")

    const prune = await serverUpdateCache({ dataDir, runningEntrypoint: undefined }).prune([])

    expect(prune).toEqual({ kept: [], removed: [], failures: [] })
  })

  it("keeps going past entries it can't remove and reports them", async () => {
    const removed: Array<string> = []
    const cache = serverUpdateCache({
      dataDir: "/data",
      runningEntrypoint: undefined,
      fs: fakeFs({
        list: async () => ["0.1.100", "0.1.101", "0.1.102"],
        remove: async (path) => {
          if (path.endsWith("0.1.100")) throw failure("EACCES")
          if (path.endsWith("0.1.101")) throw "EBUSY"
          removed.push(path)
        }
      })
    })

    const prune = await cache.prune([])

    expect(prune).toEqual({
      kept: [],
      removed: ["0.1.102"],
      failures: [
        { entry: "0.1.100", message: "EACCES" },
        { entry: "0.1.101", message: "EBUSY" }
      ]
    })
    expect(removed).toEqual(["/data/server-updates/0.1.102"])
  })

  it("rejects when the cache directory can't be read", async () => {
    const cache = serverUpdateCache({
      dataDir: "/data",
      runningEntrypoint: undefined,
      fs: fakeFs({
        list: async () => {
          throw failure("EACCES")
        }
      })
    })

    await expect(cache.prune([])).rejects.toThrow("EACCES")
  })
})

describe("serverUpdateCache discard", () => {
  it("removes only the named version", async () => {
    const home = makeHome()
    const dataDir = seedInstall(home, ["0.1.100", "0.1.101"])
    const cache = serverUpdateCache({ dataDir, runningEntrypoint: undefined })

    const prune = await cache.discard("0.1.101")

    expect(prune.removed).toEqual(["0.1.101"])
    expect(cacheEntries(dataDir)).toEqual(["0.1.100"])
    expect(existsSync(cache.versionDirectory("0.1.100"))).toBe(true)
    expect(existsSync(cache.versionDirectory("0.1.101"))).toBe(false)
  })

  it("never removes the version the server is running from", async () => {
    const home = makeHome()
    const dataDir = seedInstall(home, ["0.1.100"])
    const cache = serverUpdateCache({
      dataDir,
      runningEntrypoint: runtimeEntrypoint(dataDir, "0.1.100")
    })

    const prune = await cache.discard("0.1.100")

    expect(prune).toEqual({ kept: ["0.1.100"], removed: [], failures: [] })
    expect(existsSync(runtimeEntrypoint(dataDir, "0.1.100"))).toBe(true)
  })

  it("ignores version names that point outside the cache", async () => {
    const home = makeHome()
    const dataDir = seedInstall(home, ["0.1.100"])
    const cache = serverUpdateCache({ dataDir, runningEntrypoint: undefined })

    const prune = await cache.discard(join("..", "..", "server.next"))

    expect(prune.removed).toEqual([])
    expect(existsSync(join(home, ".codevisor", "server.next", "main.js"))).toBe(true)
    expect(cacheEntries(dataDir)).toEqual(["0.1.100"])
  })
})

describe("serverUpdateCache concurrency", () => {
  it("runs one cleanup at a time so a later one sees the earlier result", async () => {
    const entries = new Set(["0.1.100", "0.1.101"])
    const removal = Promise.withResolvers<void>()
    const removalStarted = Promise.withResolvers<void>()
    const listings: Array<ReadonlyArray<string>> = []
    const cache = serverUpdateCache({
      dataDir: "/data",
      runningEntrypoint: undefined,
      fs: fakeFs({
        list: async () => {
          listings.push([...entries])
          return [...entries]
        },
        remove: async (path) => {
          removalStarted.resolve()
          await removal.promise
          entries.delete(path.slice("/data/server-updates/".length))
        }
      })
    })

    const bootPrune = cache.prune([])
    await removalStarted.promise
    const discard = cache.discard("0.1.101")
    expect(listings).toEqual([["0.1.100", "0.1.101"]])

    removal.resolve()

    expect((await bootPrune).removed).toEqual(["0.1.100", "0.1.101"])
    expect(await discard).toEqual({ kept: [], removed: [], failures: [] })
    expect(listings).toEqual([["0.1.100", "0.1.101"], []])
  })

  it("keeps serving cleanups after one fails", async () => {
    let listings = 0
    const cache = serverUpdateCache({
      dataDir: "/data",
      runningEntrypoint: undefined,
      fs: fakeFs({
        list: async () => {
          listings += 1
          if (listings === 1) throw failure("EIO")
          return ["0.1.100"]
        }
      })
    })

    const failed = cache.prune([])
    const next = cache.prune([])

    await expect(failed).rejects.toThrow("EIO")
    expect((await next).removed).toEqual(["0.1.100"])
  })
})

describe("serverUpdateCache ensureRoomFor", () => {
  it("allows a download when the disk has room for the archive, its extraction and a reserve", async () => {
    const checked: Array<string> = []
    const cache = serverUpdateCache({
      dataDir: "/data",
      runningEntrypoint: undefined,
      fs: fakeFs({
        freeBytes: async (path) => {
          checked.push(path)
          return requiredFreeBytes(160_000_000)
        }
      })
    })

    await expect(cache.ensureRoomFor(160_000_000)).resolves.toBeUndefined()
    expect(checked).toEqual(["/data"])
  })

  it("refuses a download that wouldn't fit, with a message that says how much is needed", async () => {
    const cache = serverUpdateCache({
      dataDir: "/data",
      runningEntrypoint: undefined,
      fs: fakeFs({ freeBytes: async () => requiredFreeBytes(undefined) - 1 })
    })

    await expect(cache.ensureRoomFor(undefined)).rejects.toThrow(
      "Not enough free disk space to update the Codevisor server: it needs 3.5 GB free in /data, " +
        "but only 3.5 GB is available. Free up space, then try the update again."
    )
  })

  it("sizes the requirement from the archive, assuming 512 MB when its size is unknown", () => {
    expect(requiredFreeBytes(gigabyte)).toBe(6 * gigabyte)
    expect(requiredFreeBytes(undefined)).toBe(3.5 * gigabyte)
  })

  it("reads free space from the real filesystem", async () => {
    const home = makeHome()

    await expect(defaultServerUpdateCacheFs.freeBytes(home)).resolves.toBeGreaterThan(0)
  })
})

describe("explainDiskFull", () => {
  it("turns a full disk into an actionable error and leaves other errors alone", () => {
    const diskFull = failure("ENOSPC")
    const explained = explainDiskFull(diskFull, "/data/server-updates")
    const other = new Error("HTTP 500")

    expect(explained).toBeInstanceOf(Error)
    expect(explained).toMatchObject({
      message:
        "The disk is full, so the Codevisor server update couldn't be saved in /data/server-updates. " +
        "Free up space, then try the update again.",
      cause: diskFull
    })
    expect(explainDiskFull(other, "/data")).toBe(other)
    expect(explainDiskFull("ENOSPC", "/data")).toBe("ENOSPC")
    expect(explainDiskFull(null, "/data")).toBeNull()
  })
})
