import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import {
  APP_UPDATE_CHANNEL_FILE,
  APP_UPDATE_FEED_FILE,
  APP_UPDATE_STATUS_FILE,
  APP_UPDATE_STATUS_TTL_MS,
  channelFromSyncedValue,
  readAppUpdateApplyState,
  readMachineUpdateChannel,
  readMachineUpdateFeedURL
} from "./app-hosted.js"

describe("channelFromSyncedValue", () => {
  it("accepts only the two known channels", () => {
    expect(channelFromSyncedValue("alpha")).toBe("alpha")
    expect(channelFromSyncedValue("stable")).toBe("stable")
    expect(channelFromSyncedValue("nightly")).toBeUndefined()
    expect(channelFromSyncedValue(undefined)).toBeUndefined()
    expect(channelFromSyncedValue(42)).toBeUndefined()
  })
})

describe("app-hosted update files", () => {
  let dataDir: string

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "codevisor-app-hosted-"))
  })

  afterEach(() => {
    rmSync(dataDir, { recursive: true, force: true })
  })

  describe("readMachineUpdateChannel", () => {
    it("is undefined when the host app never wrote a channel", () => {
      expect(readMachineUpdateChannel(dataDir)).toBeUndefined()
    })

    it("reads the app's channel preference", () => {
      writeFileSync(join(dataDir, APP_UPDATE_CHANNEL_FILE), "alpha\n")
      expect(readMachineUpdateChannel(dataDir)).toBe("alpha")
      writeFileSync(join(dataDir, APP_UPDATE_CHANNEL_FILE), "stable\n")
      expect(readMachineUpdateChannel(dataDir)).toBe("stable")
    })

    it("treats unknown contents as stable and empty files as absent", () => {
      writeFileSync(join(dataDir, APP_UPDATE_CHANNEL_FILE), "nightly")
      expect(readMachineUpdateChannel(dataDir)).toBe("stable")
      writeFileSync(join(dataDir, APP_UPDATE_CHANNEL_FILE), "  \n")
      expect(readMachineUpdateChannel(dataDir)).toBeUndefined()
    })

    it("is undefined when the file cannot be read", () => {
      mkdirSync(join(dataDir, APP_UPDATE_CHANNEL_FILE))
      expect(readMachineUpdateChannel(dataDir)).toBeUndefined()
    })
  })

  describe("readMachineUpdateFeedURL", () => {
    it("is undefined when the host app never wrote a feed", () => {
      expect(readMachineUpdateFeedURL(dataDir)).toBeUndefined()
    })

    it("reads the app's Sparkle feed URL", () => {
      writeFileSync(
        join(dataDir, APP_UPDATE_FEED_FILE),
        "https://updates.codevisor.dev/appcast-x64.xml\n"
      )
      expect(readMachineUpdateFeedURL(dataDir)).toBe(
        "https://updates.codevisor.dev/appcast-x64.xml"
      )
      writeFileSync(join(dataDir, APP_UPDATE_FEED_FILE), "http://127.0.0.1:8000/appcast.xml")
      expect(readMachineUpdateFeedURL(dataDir)).toBe("http://127.0.0.1:8000/appcast.xml")
    })

    it("rejects anything that is not an http(s) URL", () => {
      for (const contents of ["file:///tmp/appcast.xml", "not a url", "", "  \n"]) {
        writeFileSync(join(dataDir, APP_UPDATE_FEED_FILE), contents)
        expect(readMachineUpdateFeedURL(dataDir)).toBeUndefined()
      }
      rmSync(join(dataDir, APP_UPDATE_FEED_FILE))
      mkdirSync(join(dataDir, APP_UPDATE_FEED_FILE))
      expect(readMachineUpdateFeedURL(dataDir)).toBeUndefined()
    })
  })

  describe("readAppUpdateApplyState", () => {
    const at = "2026-08-24T00:00:00.000Z"
    const now = () => Date.parse(at) + 1000

    const writeStatus = (value: unknown) => {
      writeFileSync(join(dataDir, APP_UPDATE_STATUS_FILE), JSON.stringify(value))
    }

    it("is undefined when the host app reported nothing", () => {
      expect(readAppUpdateApplyState(dataDir, now)).toBeUndefined()
    })

    it("reads a failure report with its message and target", () => {
      writeStatus({
        state: "failed",
        message: "Sparkle: no signature",
        targetVersion: "0.2.0",
        at
      })
      expect(readAppUpdateApplyState(dataDir, now)).toEqual({
        state: "failed",
        message: "Sparkle: no signature",
        targetVersion: "0.2.0",
        at
      })
    })

    it("reads an in-progress report without optional fields", () => {
      writeStatus({ state: "installing", at })
      expect(readAppUpdateApplyState(dataDir, now)).toEqual({
        state: "installing",
        message: undefined,
        targetVersion: undefined,
        at
      })
    })

    it("reads a fresh report against the real clock by default", () => {
      vi.useFakeTimers({ toFake: ["Date"] })
      try {
        vi.setSystemTime(new Date(at))
        writeStatus({ state: "installing", at })
        expect(readAppUpdateApplyState(dataDir)?.state).toBe("installing")
      } finally {
        vi.useRealTimers()
      }
    })

    it.each([
      [0.42, 0.42],
      [-1, 0],
      [2, 1],
      ["42%", undefined],
      [null, undefined]
    ])("reads and bounds progress %s", (progress, expected) => {
      writeStatus({ state: "installing", message: "Downloading…", progress, at })
      expect(readAppUpdateApplyState(dataDir, now)?.progress).toBe(expected)
      writeStatus({ state: "failed", progress, at })
      expect(readAppUpdateApplyState(dataDir, now)?.progress).toBeUndefined()
    })

    it.each([
      [660, 660],
      [0, undefined],
      [-3, undefined],
      [66.5, undefined],
      ["660", undefined]
    ])("reads the build being installed %s", (targetBuildNumber, expected) => {
      writeStatus({ state: "installing", targetBuildNumber, at })
      expect(readAppUpdateApplyState(dataDir, now)?.targetBuildNumber).toBe(expected)
    })

    it("ignores stale reports left behind by an interrupted session", () => {
      writeStatus({ state: "failed", at })
      const later = () => Date.parse(at) + APP_UPDATE_STATUS_TTL_MS + 1
      expect(readAppUpdateApplyState(dataDir, later)).toBeUndefined()
    })

    it("ignores malformed reports", () => {
      writeFileSync(join(dataDir, APP_UPDATE_STATUS_FILE), "not json")
      expect(readAppUpdateApplyState(dataDir, now)).toBeUndefined()
      writeFileSync(join(dataDir, APP_UPDATE_STATUS_FILE), "null")
      expect(readAppUpdateApplyState(dataDir, now)).toBeUndefined()
      writeFileSync(join(dataDir, APP_UPDATE_STATUS_FILE), "42")
      expect(readAppUpdateApplyState(dataDir, now)).toBeUndefined()
      writeStatus({ state: "done", at })
      expect(readAppUpdateApplyState(dataDir, now)).toBeUndefined()
      writeStatus({ state: "failed" })
      expect(readAppUpdateApplyState(dataDir, now)).toBeUndefined()
      writeStatus({ state: "failed", at: "not-a-date" })
      expect(readAppUpdateApplyState(dataDir, now)).toBeUndefined()
    })
  })
})
