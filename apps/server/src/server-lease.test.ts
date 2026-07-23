import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { acquireServerLease } from "./server-lease.js"

const temporaryDirectories: string[] = []

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true }))
  )
})

describe("server lease", () => {
  it("allows only one server to own a database", async () => {
    const directory = await mkdtemp(join(tmpdir(), "codevisor-server-lease-"))
    temporaryDirectories.push(directory)
    const databasePath = join(directory, "codevisor.sqlite")
    const first = await acquireServerLease(databasePath, {
      bootId: "boot-a",
      appOwned: true,
      pid: 42,
      now: () => new Date("2026-07-23T00:00:00.000Z")
    })

    await expect(
      acquireServerLease(databasePath, { bootId: "boot-b", appOwned: true })
    ).rejects.toThrow(/pid 42, boot boot-a/)

    await first.release()
    const second = await acquireServerLease(databasePath, {
      bootId: "boot-b",
      appOwned: false
    })
    await second.release()
  })

  it("publishes boot-scoped owner metadata for diagnostics", async () => {
    const directory = await mkdtemp(join(tmpdir(), "codevisor-server-lease-"))
    temporaryDirectories.push(directory)
    const databasePath = join(directory, "codevisor.sqlite")
    const lease = await acquireServerLease(databasePath, {
      bootId: "diagnostic-boot",
      appOwned: true,
      pid: 81,
      now: () => new Date("2026-07-23T01:02:03.000Z")
    })

    await expect(
      readFile(`${databasePath}.server-owner.json`, "utf8").then(JSON.parse)
    ).resolves.toMatchObject({
      bootId: "diagnostic-boot",
      pid: 81,
      databasePath,
      appOwned: true,
      startedAt: "2026-07-23T01:02:03.000Z"
    })

    await lease.release()
  })

  it("recovers when diagnostics metadata is missing or malformed", async () => {
    const directory = await mkdtemp(join(tmpdir(), "codevisor-server-lease-"))
    temporaryDirectories.push(directory)
    const databasePath = join(directory, "codevisor.sqlite")
    const metadataPath = `${databasePath}.server-owner.json`
    const first = await acquireServerLease(databasePath, {
      bootId: "boot-without-metadata",
      appOwned: true
    })

    await rm(metadataPath)
    await expect(
      acquireServerLease(databasePath, { bootId: "contender", appOwned: false })
    ).rejects.toThrow(`Another Codevisor server owns ${databasePath}`)
    await first.release()

    const second = await acquireServerLease(databasePath, {
      bootId: "boot-with-malformed-metadata",
      appOwned: true
    })
    await writeFile(metadataPath, "{}\n", "utf8")
    await expect(
      acquireServerLease(databasePath, { bootId: "contender", appOwned: false })
    ).rejects.toThrow(/an unknown process/)
    await second.release()
  })

  it("supports bounded replacement waiting and idempotent release", async () => {
    const directory = await mkdtemp(join(tmpdir(), "codevisor-server-lease-"))
    temporaryDirectories.push(directory)
    const lease = await acquireServerLease(join(directory, "codevisor.sqlite"), {
      bootId: "replacement-boot",
      appOwned: true,
      waitForOwnership: true
    })

    await lease.release()
    await lease.release()
  })
})
