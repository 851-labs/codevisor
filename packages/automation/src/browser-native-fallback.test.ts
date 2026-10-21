import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it, vi } from "vitest"

const mocks = vi.hoisted(() => ({ connect: vi.fn(), launch: vi.fn() }))
vi.mock("./browser-chromium.js", async (original) => ({
  ...(await original<typeof import("./browser-chromium.js")>()),
  launchManagedBrowser: mocks.launch,
  systemChromePath: () => "/fixture/chromium",
  userChromiumIsRunning: () => false
}))
import { headedUserAgent, managedBrowserHeadless } from "./browser-chromium.js"
import type { BrowserHostRegistry, BrowserHostSummary } from "./browser-host-registry.js"
import { browserResultValue } from "./browser-repl.js"
import { makeBrowserUseProvider } from "./browser-use-provider.js"

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

const studio: BrowserHostSummary = { id: "studio", name: "Mac Studio", lastActiveAt: 1 }
const macbook: BrowserHostSummary = { id: "macbook", name: "MacBook Pro", lastActiveAt: 2 }

const hostRegistry = () => {
  const current: { host?: BrowserHostSummary; lostHost?: string } = {}
  const registry: BrowserHostRegistry = {
    accept: () => {},
    hosts: () => (current.host === undefined ? [] : [current.host]),
    state: () => ({ ...current }),
    connect: mocks.connect,
    forgetSession: () => {},
    close: () => {}
  }
  return { registry, current }
}

const builtinProvider = (directory: string) => {
  const hosts = hostRegistry()
  return { provider: makeBrowserUseProvider(directory, undefined, hosts.registry), hosts }
}

const status = (provider: ReturnType<typeof makeBrowserUseProvider>, sessionId: string) =>
  provider.invoke({ sessionId }, "status", {}).then(browserResultValue)

describe("built-in browser recovery", () => {
  it("says the tabs were lost when the host Mac goes away and moves to another Mac app", async () => {
    const directory = mkdtempSync(join(tmpdir(), "native-browser-lost-"))
    const { provider, hosts } = builtinProvider(directory)
    const context = { sessionId: "fixture-session" }
    const first = connection("studio-tab")
    hosts.current.host = studio
    mocks.connect.mockResolvedValue({ connection: first, host: studio })
    try {
      await provider.invoke(context, "use_backend", { backend: "builtin" })
      expect(await status(provider, context.sessionId)).toMatchObject({
        builtin: {
          state: "ready",
          visibleToUser: true,
          host: "This chat's browser pane in Codevisor on Mac Studio"
        }
      })
      expect(JSON.stringify(await provider.invoke(context, "openTabs", {}))).toContain("studio-tab")
      first.closed = true
      hosts.current.host = macbook
      hosts.current.lostHost = "Mac Studio"
      const lost = await provider.invoke(context, "openTabs", {})
      expect(lost.isError).toBe(true)
      expect(JSON.stringify(lost)).toContain(
        "The Codevisor app on Mac Studio disconnected, so this chat's built-in browser tabs were lost."
      )
      expect(JSON.stringify(lost)).toContain("opens new tabs in Codevisor on MacBook Pro")
      expect(await status(provider, context.sessionId)).toMatchObject({
        builtin: { state: "ready", lost: expect.stringContaining("Mac Studio") }
      })
      mocks.connect.mockResolvedValue({ connection: connection("macbook-tab"), host: macbook })
      expect(JSON.stringify(await provider.invoke(context, "openTabs", {}))).toContain(
        "macbook-tab"
      )
      expect(mocks.launch).not.toHaveBeenCalled()
    } finally {
      await provider.close()
      rmSync(directory, { recursive: true, force: true })
    }
  })
  it("falls back safely if the app disconnects before initialization completes", async () => {
    const directory = mkdtempSync(join(tmpdir(), "native-browser-setup-"))
    const { provider, hosts } = builtinProvider(directory)
    const native = connection("native-tab")
    native.send.mockRejectedValueOnce(Error("app closed during setup"))
    hosts.current.host = studio
    mocks.connect.mockResolvedValue({ connection: native, host: studio })
    mocks.launch.mockResolvedValue({ connection: connection("fallback-tab") })
    try {
      await provider.invoke({ sessionId: "fixture" }, "use_backend", { backend: "builtin" })
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
  it("runs headless when no Mac app is connected and returns to the pane at the next response", async () => {
    const directory = mkdtempSync(join(tmpdir(), "clientless-browser-"))
    const { provider, hosts } = builtinProvider(directory)
    mocks.connect.mockResolvedValue({ reason: "No Codevisor Mac app is connected to this server." })
    mocks.launch.mockResolvedValue({ connection: connection("independent-tab") })
    const context = { sessionId: "fixture" }
    try {
      await provider.invoke(context, "use_backend", { backend: "builtin" })
      expect(await status(provider, context.sessionId)).toMatchObject({
        selected: "builtin",
        builtin: {
          state: "unavailable",
          visibleToUser: false,
          reason: "No Codevisor Mac app is connected to this server.",
          fallback: "Calls run in the headless managed browser instead."
        }
      })
      expect(JSON.stringify(await provider.invoke(context, "openTabs", {}))).toContain(
        "independent-tab"
      )
      expect(mocks.connect).toHaveBeenCalledWith("fixture")
      await provider.invoke(context, "js", { code: "var retained = 7" })
      hosts.current.host = studio
      const native = connection("recovered-local-tab")
      mocks.connect.mockResolvedValue({ connection: native, host: studio })
      expect(JSON.stringify(await provider.invoke(context, "openTabs", {}))).toContain(
        "independent-tab"
      )
      expect(await status(provider, context.sessionId)).toMatchObject({
        builtin: { state: "unavailable" }
      })
      expect(browserResultValue(await provider.invoke(context, "js", { code: "retained" }))).toBe(7)
      await provider.beginTurn(context.sessionId)
      expect(await status(provider, context.sessionId)).toMatchObject({
        builtin: { state: "ready", visibleToUser: true }
      })
      expect(JSON.stringify(await provider.invoke(context, "openTabs", {}))).toContain(
        "recovered-local-tab"
      )
      expect(
        browserResultValue(await provider.invoke(context, "js", { code: "typeof retained" }))
      ).toBe("undefined")
      expect(mocks.launch).toHaveBeenCalledOnce()
      expect(native.close).not.toHaveBeenCalled()
    } finally {
      await provider.close()
      rmSync(directory, { recursive: true, force: true })
    }
  })
  it("detaches a completed native session without closing the user's app or pages", async () => {
    const directory = mkdtempSync(join(tmpdir(), "native-browser-detach-"))
    const { provider, hosts } = builtinProvider(directory)
    const native = connection("native-tab")
    hosts.current.host = studio
    mocks.connect.mockResolvedValue({ connection: native, host: studio })
    try {
      await provider.invoke({ sessionId: "fixture" }, "use_backend", { backend: "builtin" })
      await provider.invoke({ sessionId: "fixture" }, "openTabs", {})
      await provider.closeSession?.("fixture")
      expect(native.close).toHaveBeenCalledOnce()
      expect(
        native.send.mock.calls.filter(
          ([method]) => method === "Browser.close" || method === "Target.closeTarget"
        )
      ).toHaveLength(0)
      await provider.invoke({ sessionId: "fixture" }, "use_backend", { backend: "builtin" })
      await provider.invoke({ sessionId: "fixture" }, "openTabs", {})
      expect(mocks.connect).toHaveBeenCalledTimes(2)
    } finally {
      await provider.close()
      rmSync(directory, { recursive: true, force: true })
    }
  })
  it("refuses browser calls until the chat picks a browser, and says what is available", async () => {
    const directory = mkdtempSync(join(tmpdir(), "unselected-browser-"))
    mocks.connect.mockResolvedValue({ reason: "No local app" })
    const { provider } = builtinProvider(directory)
    const context = { sessionId: "fixture" }
    try {
      await provider.beginTurn(context.sessionId, { clientPlatform: "ios" })
      const refused = await provider.invoke(context, "tabs", { action: "new" })
      expect(refused.isError).toBe(true)
      expect(JSON.stringify(refused)).toContain("No browser is selected for this chat")
      expect(JSON.stringify(refused)).toContain('\\"platform\\": \\"ios\\"')
      expect(mocks.launch).not.toHaveBeenCalled()
      expect(browserResultValue(await provider.invoke(context, "status", {}))).toMatchObject({
        selected: null,
        user: { platform: "ios" },
        managed: { state: "ready", visibleToUser: false }
      })
    } finally {
      await provider.close()
      rmSync(directory, { recursive: true, force: true })
    }
  })
  it("runs managed Chromium headless unless a developer turns it off", () => {
    expect(managedBrowserHeadless({})).toBe(true)
    expect(managedBrowserHeadless({ CODEVISOR_BROWSER_HEADLESS: "0" })).toBe(false)
  })
  it("reports headless Chrome with the same user agent as headed Chrome", () => {
    const headed =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36"
    expect(
      headedUserAgent({
        product: "Chrome/155.0.8059.85",
        userAgent: headed.replace("Chrome/", "HeadlessChrome/")
      })
    ).toBe(headed)
    expect(headedUserAgent({ product: "Chrome/155.0.8059.85", userAgent: headed })).toBe(headed)
    expect(headedUserAgent({ product: "Chrome/156.0.8100.1", userAgent: headed })).toBeUndefined()
  })
})
