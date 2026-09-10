import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"

const mocks = vi.hoisted(() => ({ connect: vi.fn(), launch: vi.fn() }))
vi.mock("./browser-native-connection.js", () => ({ connectNativeBrowser: mocks.connect }))
vi.mock("./browser-chromium.js", async (original) => ({
  ...(await original<typeof import("./browser-chromium.js")>()),
  launchManagedBrowser: mocks.launch,
  systemChromePath: () => "/fixture/chromium",
  userChromiumIsRunning: () => false
}))
import { browserResultValue } from "./browser-repl.js"
import { makeBrowserUseProvider } from "./browser-use-provider.js"
import { managedBrowserHeadless } from "./browser-chromium.js"

const connection = (name: string) => ({
  closed: false,
  send: vi.fn(async (method: string) =>
    method === "Target.getTargets"
      ? { targetInfos: [{ targetId: name, type: "page", url: "about:blank", title: name }] }
      : {}
  ),
  on: () => () => {},
  setSessionRecoveryHandler: () => () => {},
  close: vi.fn(async () => {})
})
afterEach(() => vi.clearAllMocks())

describe("built-in browser recovery", () => {
  it("reports an interrupted action, discards the old runtime, and keeps same-server fallback until the next response", async () => {
    const directory = mkdtempSync(join(tmpdir(), "native-browser-fallback-"))
    const native = connection("native-tab")
    const managed = connection("fallback-tab")
    mocks.connect.mockResolvedValue({ connection: native })
    mocks.launch.mockResolvedValue({ connection: managed })
    const provider = makeBrowserUseProvider(directory)
    const context = { sessionId: "fixture-session" }
    try {
      const first = await provider.invoke(context, "openTabs", {})
      expect(JSON.stringify(first)).toContain("native-tab")
      expect(provider.sessionBackend(context.sessionId)).toBe("builtin")
      native.closed = true
      const interrupted = await provider.invoke(context, "openTabs", {})
      expect(interrupted.isError).toBe(true)
      expect(JSON.stringify(interrupted)).toContain("NOT retried")
      expect(mocks.launch).not.toHaveBeenCalled()
      const next = await provider.invoke(context, "openTabs", {})
      expect(JSON.stringify(next)).toContain("fallback-tab")
      expect(JSON.stringify(next)).not.toContain("native-tab")
      native.closed = false
      await provider.invoke(context, "openTabs", {})
      expect(mocks.connect).toHaveBeenCalledTimes(1)
      expect(mocks.launch).toHaveBeenCalledTimes(1)
      expect(
        browserResultValue(await provider.invoke(context, "connection_status", {}))
      ).toMatchObject({ requestedBackend: "builtin", backend: "managed", connected: true })
      await provider.beginTurn(context.sessionId, "builtin")
      expect(JSON.stringify(await provider.invoke(context, "openTabs", {}))).toContain("native-tab")
      expect(mocks.connect).toHaveBeenCalledTimes(2)
      expect(managed.close).not.toHaveBeenCalled()
      expect(native.send.mock.calls.filter(([method]) => method === "Browser.close")).toHaveLength(
        0
      )
    } finally {
      await provider.close()
      rmSync(directory, { recursive: true, force: true })
    }
  })
  it("falls back safely if the app disconnects before initialization completes", async () => {
    const directory = mkdtempSync(join(tmpdir(), "native-browser-setup-"))
    const native = connection("native-tab")
    native.send.mockRejectedValueOnce(Error("app closed during setup"))
    mocks.connect.mockResolvedValue({ connection: native })
    mocks.launch.mockResolvedValue({ connection: connection("fallback-tab") })
    const provider = makeBrowserUseProvider(directory)
    try {
      expect(
        JSON.stringify(await provider.invoke({ sessionId: "fixture" }, "openTabs", {}))
      ).toContain("fallback-tab")
      expect(native.close).toHaveBeenCalledOnce()
      expect(native.send.mock.calls.map(([method]) => method)).toEqual([
        "Target.setDiscoverTargets"
      ])
    } finally {
      await provider.close()
      rmSync(directory, { recursive: true, force: true })
    }
  })
  it("uses independent Chromium when no local app is reachable", async () => {
    const directory = mkdtempSync(join(tmpdir(), "clientless-browser-"))
    mocks.connect.mockResolvedValue({ reason: "No local app" })
    mocks.launch.mockResolvedValue({ connection: connection("independent-tab") })
    const provider = makeBrowserUseProvider(directory)
    const context = { sessionId: "fixture" }
    try {
      await provider.beginTurn(context.sessionId, "builtin")
      expect(
        browserResultValue(await provider.invoke(context, "connection_status", {}))
      ).toMatchObject({ backend: "unconnected", connected: false })
      expect(mocks.launch).not.toHaveBeenCalled()
      expect(
        JSON.stringify(await provider.invoke({ sessionId: "fixture" }, "openTabs", {}))
      ).toContain("independent-tab")
      expect(mocks.connect).toHaveBeenCalledWith(directory, "fixture")
      await provider.invoke(context, "js", { code: "var retained = 7" })
      const status = () =>
        provider.invoke(context, "connection_status", {}).then(browserResultValue)
      expect(await status()).toMatchObject({
        requestedBackend: "builtin",
        backend: "managed",
        fallbackReason: "No local app",
        connected: true
      })
      await provider.beginTurn(context.sessionId, "builtin")
      await provider.invoke(context, "openTabs", {})
      expect(mocks.connect).toHaveBeenCalledTimes(2)
      expect(mocks.launch).toHaveBeenCalledOnce()
      expect(browserResultValue(await provider.invoke(context, "js", { code: "retained" }))).toBe(7)
      const native = connection("recovered-local-tab")
      mocks.connect.mockResolvedValue({ connection: native })
      // Availability changing in the middle of a response does not switch it.
      expect(JSON.stringify(await provider.invoke(context, "openTabs", {}))).toContain(
        "independent-tab"
      )
      await provider.beginTurn(context.sessionId, "builtin")
      expect(await status()).toMatchObject({ backend: "builtin", connected: true })
      expect(await status()).not.toHaveProperty("fallbackReason")
      expect(
        browserResultValue(await provider.invoke(context, "js", { code: "typeof retained" }))
      ).toBe("undefined")
      await provider.beginTurn(context.sessionId, "builtin")
      expect(mocks.connect).toHaveBeenCalledTimes(3)
      expect(native.close).not.toHaveBeenCalled()
    } finally {
      await provider.close()
      rmSync(directory, { recursive: true, force: true })
    }
  })
  it("detaches a completed native session without closing the user's app or pages", async () => {
    const directory = mkdtempSync(join(tmpdir(), "native-browser-detach-"))
    const native = connection("native-tab")
    mocks.connect.mockResolvedValue({ connection: native })
    const provider = makeBrowserUseProvider(directory)
    try {
      await provider.invoke({ sessionId: "fixture" }, "openTabs", {})
      await provider.closeSession?.("fixture")
      expect(native.close).toHaveBeenCalledOnce()
      expect(
        native.send.mock.calls.filter(
          ([method]) => method === "Browser.close" || method === "Target.closeTarget"
        )
      ).toHaveLength(0)
      await provider.invoke({ sessionId: "fixture" }, "openTabs", {})
      expect(mocks.connect).toHaveBeenCalledTimes(2)
    } finally {
      await provider.close()
      rmSync(directory, { recursive: true, force: true })
    }
  })
  it("detects GUI-less Linux and respects an explicit display policy", () => {
    expect(managedBrowserHeadless("linux", {})).toBe(true)
    expect(managedBrowserHeadless("linux", { DISPLAY: ":0" })).toBe(false)
    expect(managedBrowserHeadless("linux", { WAYLAND_DISPLAY: "wayland-0" })).toBe(false)
    expect(managedBrowserHeadless("darwin", {})).toBe(false)
    expect(managedBrowserHeadless("linux", { CODEVISOR_BROWSER_HEADLESS: "0" })).toBe(false)
    expect(managedBrowserHeadless("darwin", { CODEVISOR_BROWSER_HEADLESS: "1" })).toBe(true)
  })
})
