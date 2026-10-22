import { describe, expect, it } from "vitest"

import {
  builtinLostResult,
  browserExtensionState,
  browserStatusReport,
  chromeNotConnectedResult
} from "./browser-use-status.js"

const ready = { ready: true }

const state = (
  connected: boolean,
  chromeAvailable: boolean,
  installationState: "installed" | "not_installed" | "unknown",
  needsUpdate = false
) => browserExtensionState({ connected, chromeAvailable, installationState, needsUpdate })

const text = (result: ReturnType<typeof builtinLostResult>) => JSON.stringify(result.content)

describe("browser status", () => {
  it("tells the model whether the user's Chrome needs opening, installing, or nothing", () => {
    expect(state(true, true, "installed")).toBe("connected")
    expect(state(false, false, "installed")).toBe("chrome_not_installed")
    expect(state(false, true, "installed")).toBe("installed_not_connected")
    expect(state(false, true, "not_installed")).toBe("not_installed")
    expect(state(false, true, "unknown")).toBe("not_connected")
    expect(state(false, true, "installed", true)).toBe("update_required")
    expect(state(true, true, "installed", true)).toBe("connected")
  })

  it("reports which browsers the user can see, with the fallback and setup failures", () => {
    expect(
      browserStatusReport({
        selected: "builtin",
        platform: undefined,
        managedError: "Chromium download failed",
        builtin: { ready: false, reason: "This session is not open in the Codevisor app." },
        extension: "connected"
      })
    ).toEqual({
      selected: "builtin",
      managed: { state: "unavailable", visibleToUser: false, reason: "Chromium download failed" },
      builtin: {
        state: "unavailable",
        visibleToUser: false,
        reason: "This session is not open in the Codevisor app.",
        fallback: "Calls run in the headless managed browser instead."
      },
      extension: { state: "connected", visibleToUser: true }
    })
    const report = browserStatusReport({
      selected: "extension",
      platform: "macos",
      managedError: undefined,
      builtin: ready,
      extension: "installed_not_connected"
    })
    expect(report).toMatchObject({
      user: { platform: "macos" },
      builtin: { state: "ready", visibleToUser: true },
      extension: { state: "installed_not_connected", visibleToUser: false }
    })
    const refused = chromeNotConnectedResult(report)
    expect(refused.isError).toBe(true)
    expect(JSON.stringify(refused.content)).toContain("installed_not_connected")
  })

  it("says when the host Mac went away and where the next tabs open", () => {
    expect(
      text(
        builtinLostResult({
          lostHost: "Mac Studio",
          host: { id: "macbook", name: "MacBook Pro", lastActiveAt: 0 }
        })
      )
    ).toContain("The Codevisor app on Mac Studio disconnected")
    const fallback = text(builtinLostResult({}))
    expect(fallback).toContain("The built-in browser disconnected.")
    expect(fallback).toContain("headless managed browser")
  })
})
