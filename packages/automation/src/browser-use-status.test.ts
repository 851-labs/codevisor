import { describe, expect, it } from "vitest"

import {
  builtinLostResult,
  builtinUnreachableMessage,
  browserExtensionState,
  browserLabel,
  browserStatusReport,
  chromeNotConnectedResult
} from "./browser-use-status.js"

const state = (
  connected: boolean,
  chromeAvailable: boolean,
  installationState: "installed" | "not_installed" | "unknown"
) => browserExtensionState({ connected, chromeAvailable, installationState })

const text = (result: ReturnType<typeof builtinLostResult>) => JSON.stringify(result.content)

describe("browser status", () => {
  it("tells the model whether the user's Chrome needs opening, installing, or nothing", () => {
    expect(state(true, true, "installed")).toBe("connected")
    expect(state(false, false, "installed")).toBe("chrome_not_installed")
    expect(state(false, true, "installed")).toBe("installed_not_connected")
    expect(state(false, true, "not_installed")).toBe("not_installed")
    expect(state(false, true, "unknown")).toBe("not_connected")
  })

  it("reports which browsers the user can see, what each Mac app said, and setup failures", () => {
    const macbook = { id: "macbook", name: "MacBook Pro", lastActiveAt: 2 }
    expect(
      browserStatusReport({
        selected: "builtin",
        platform: undefined,
        managedError: "Chromium download failed",
        builtin: {
          reason: "The Codevisor app on MacBook Pro can't open this chat.",
          probes: [{ host: macbook, answer: "unavailable" }]
        },
        extension: "connected"
      })
    ).toEqual({
      selected: "builtin",
      managed: { state: "unavailable", visibleToUser: false, reason: "Chromium download failed" },
      builtin: {
        state: "unavailable",
        visibleToUser: false,
        reason:
          "The Codevisor app on MacBook Pro can't open this chat. Built-in browser calls fail until a Codevisor Mac app can open this chat; they never fall back to another browser.",
        macs: [{ name: "MacBook Pro", state: "can't open this chat" }]
      },
      extension: { state: "connected", visibleToUser: true }
    })
    const report = browserStatusReport({
      selected: "extension",
      platform: "macos",
      managedError: undefined,
      builtin: {
        host: { id: "studio", name: "Mac Studio", showing: true },
        probes: [
          { host: { id: "studio", name: "Mac Studio", lastActiveAt: 1 }, answer: "focused" },
          { host: macbook, answer: "unresponsive" }
        ],
        lostHost: "Mac mini"
      },
      extension: "installed_not_connected"
    })
    expect(report).toMatchObject({
      user: { platform: "macos" },
      builtin: {
        state: "ready",
        visibleToUser: true,
        host: "This chat's browser pane in the Codevisor window on Mac Studio that shows this chat",
        macs: [
          { name: "Mac Studio", state: "shows this chat in its focused window" },
          { name: "MacBook Pro", state: expect.stringContaining("not responding") }
        ],
        lost: expect.stringContaining("Mac mini")
      },
      extension: { state: "installed_not_connected", visibleToUser: false }
    })
    const refused = chromeNotConnectedResult(report)
    expect(refused.isError).toBe(true)
    expect(JSON.stringify(refused.content)).toContain("installed_not_connected")
  })

  it("labels where calls run: the pane, a background pane, headless Chromium, or Chrome", () => {
    expect(browserLabel("builtin", { id: "studio", name: "Mac Studio", showing: false })).toEqual({
      backend: "builtin",
      host: expect.stringContaining("Codevisor on Mac Studio, in the background")
    })
    expect(browserLabel("managed", undefined).host).toContain("Headless Chromium")
    expect(browserLabel("extension", undefined).host).toBe("The user's own Chrome")
  })

  it("says when the host Mac went away and that nothing falls back", () => {
    expect(text(builtinLostResult("Mac Studio"))).toContain(
      "The Codevisor app on Mac Studio disconnected"
    )
    const lost = text(builtinLostResult(undefined))
    expect(lost).toContain("The built-in browser disconnected.")
    expect(lost).toContain("fails if no Mac app can open it")
    expect(builtinUnreachableMessage("No Codevisor Mac app is connected to this server.")).toBe(
      "The built-in browser can't be reached, so nothing ran. No Codevisor Mac app is connected to this server. Ask the user to open this chat in the Codevisor Mac app, or pick another browser with browser.use_backend (managed is headless, so the user can't see it)."
    )
  })
})
