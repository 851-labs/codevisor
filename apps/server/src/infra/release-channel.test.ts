import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import {
  machineReleaseChannel,
  releaseChannelReader,
  syncedUpdateChannel
} from "./release-channel.js"

const dataDir = (): string => mkdtempSync(join(tmpdir(), "release-channel-"))

describe("releaseChannelReader", () => {
  it("prefers the host app's channel file over the synced setting", async () => {
    const dir = dataDir()
    writeFileSync(join(dir, "app-update-channel"), "alpha\n")
    const read = Promise.resolve("stable")
    const channel = releaseChannelReader({ dataDir: dir, syncedValue: () => read })
    await read
    expect(channel()).toBe("alpha")
  })

  it("falls back to the last synced value, and to nothing when neither is known", async () => {
    let value: unknown = "alpha"
    let read = Promise.resolve(value)
    const channel = releaseChannelReader({ dataDir: dataDir(), syncedValue: () => read })
    await read
    expect(channel()).toBe("alpha")
    // Each call refreshes the synced value for the next one.
    value = "bogus"
    read = Promise.resolve(value)
    expect(channel()).toBe("alpha")
    await read
    expect(channel()).toBeUndefined()
  })

  it("treats an unreadable synced setting as unknown", async () => {
    const failed = Promise.reject(new Error("db closed"))
    const channel = releaseChannelReader({ dataDir: dataDir(), syncedValue: () => failed })
    await failed.catch(() => undefined)
    expect(channel()).toBeUndefined()
  })
})

describe("machineReleaseChannel", () => {
  const db = (entries: { key: string; value: unknown; deleted: boolean }[]) =>
    ({ getSyncEntries: () => Effect.succeed(entries) }) as unknown as Parameters<
      typeof syncedUpdateChannel
    >[0]

  it("reads the synced updateChannel setting, ignoring other and deleted entries", async () => {
    expect(
      await syncedUpdateChannel(
        db([
          { key: "theme", value: "dark", deleted: false },
          { key: "updateChannel", value: "alpha", deleted: false }
        ])
      )
    ).toBe("alpha")
    expect(
      await syncedUpdateChannel(db([{ key: "updateChannel", value: "alpha", deleted: true }]))
    ).toBeUndefined()
  })

  it("reads the channel file before the synced setting has loaded", () => {
    const dir = dataDir()
    writeFileSync(join(dir, "app-update-channel"), "alpha")
    expect(machineReleaseChannel(dir, db([]))()).toBe("alpha")
  })
})
