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
  it("reports an interrupted action, discards the old runtime, and stays on same-server fallback", async () => {
    const directory = mkdtempSync(join(tmpdir(), "native-browser-fallback-"))
    const native = connection("native-tab")
    const managed = connection("fallback-tab")
    mocks.connect.mockResolvedValue(native)
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
    mocks.connect.mockResolvedValue(native)
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
    mocks.connect.mockResolvedValue(undefined)
    mocks.launch.mockResolvedValue({ connection: connection("independent-tab") })
    const provider = makeBrowserUseProvider(directory)
    try {
      expect(
        JSON.stringify(await provider.invoke({ sessionId: "fixture" }, "openTabs", {}))
      ).toContain("independent-tab")
      expect(mocks.connect).toHaveBeenCalledWith(directory, "fixture")
    } finally {
      await provider.close()
      rmSync(directory, { recursive: true, force: true })
    }
  })
  it("detaches a completed native session without closing the user's app or pages", async () => {
    const directory = mkdtempSync(join(tmpdir(), "native-browser-detach-"))
    const native = connection("native-tab")
    mocks.connect.mockResolvedValue(native)
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
