import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import {
  APP_UPDATE_CHANNEL_FILE,
  APP_UPDATE_STATUS_FILE,
  APP_UPDATE_STATUS_TTL_MS,
  readAppUpdateApplyState,
  readMachineUpdateChannel
} from "./app-hosted.js"

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
      writeStatus({ state: "installing", at: new Date().toISOString() })
      expect(readAppUpdateApplyState(dataDir)?.state).toBe("installing")
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
