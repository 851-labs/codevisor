import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it, vi } from "vitest"

const mocks = vi.hoisted(() => ({
  connect: vi.fn(),
  launch: vi.fn(),
  probe: vi.fn()
}))
vi.mock("./browser-chromium.js", async (original) => ({
  ...(await original<typeof import("./browser-chromium.js")>()),
  launchManagedBrowser: mocks.launch,
  systemChromePath: () => "/fixture/chromium",
  userChromiumIsRunning: () => false
}))
import { headedUserAgent, managedBrowserHeadless } from "./browser-chromium.js"
import type {
  BrowserHostAnswer,
  BrowserHostRegistry,
  BrowserHostSummary
} from "./browser-host-registry.js"
import { browserResultValue } from "./browser-repl.js"
import { makeBrowserUseProvider } from "./browser-use-provider.js"

const connection = (name: string) => ({
  closed: false,
  send: vi.fn(async (method: string) =>
    method === "Target.getTargets"
      ? {
          targetInfos: [{ targetId: name, type: "page", url: "about:blank", title: name }]
        }
      : {}
  ),
  on: () => () => {},
  setSessionRecoveryHandler: () => () => {},
  close: vi.fn(async () => {})
})
afterEach(() => vi.clearAllMocks())

const studio: BrowserHostSummary = {
  id: "studio",
  name: "Mac Studio",
  lastActiveAt: 1
}
const macbook: BrowserHostSummary = {
  id: "macbook",
  name: "MacBook Pro",
  lastActiveAt: 2
}

const answers = (...pairs: ReadonlyArray<readonly [BrowserHostSummary, BrowserHostAnswer]>) =>
  pairs.map(([host, answer]) => ({ host, answer }))

const connectTo = (host: BrowserHostSummary, tab: string, showing = true) => {
  const native = connection(tab)
  mocks.connect.mockResolvedValue({
    connection: native,
    host,
    showing,
    probes: []
  })
  return native
}

const hostRegistry = () => {
  const current: { lostHost?: string } = {}
  const registry: BrowserHostRegistry = {
    accept: () => {},
    hosts: () => [],
    lostHost: () => current.lostHost,
    probe: mocks.probe,
    connect: mocks.connect,
    forgetSession: () => {},
    close: () => {}
  }
  return { registry, current }
}

const builtinProvider = (directory: string) => {
  const hosts = hostRegistry()
  mocks.probe.mockResolvedValue([])
  return {
    provider: makeBrowserUseProvider(directory, "http://127.0.0.1:43210", hosts.registry),
    hosts
  }
}

const status = (provider: ReturnType<typeof makeBrowserUseProvider>, sessionId: string) =>
  provider.invoke({ sessionId }, "status", {}).then(browserResultValue)

const tabsOf = (provider: ReturnType<typeof makeBrowserUseProvider>, sessionId: string) =>
  provider.invoke({ sessionId }, "openTabs", {}).then(browserResultValue)

describe("built-in browser routing", () => {
  it("says the tabs were lost when the host Mac goes away and moves to another Mac app", async () => {
    const directory = mkdtempSync(join(tmpdir(), "native-browser-lost-"))
    const { provider, hosts } = builtinProvider(directory)
    const context = { sessionId: "fixture-session" }
    const first = connectTo(studio, "studio-tab")
    mocks.probe.mockResolvedValue(answers([studio, "showing"]))
    try {
      await provider.invoke(context, "use_backend", { backend: "builtin" })
      expect(JSON.stringify(await tabsOf(provider, context.sessionId))).toContain("studio-tab")
      expect(await status(provider, context.sessionId)).toMatchObject({
        builtin: {
          state: "ready",
          visibleToUser: true,
          host: "This chat's browser pane in the Codevisor window on Mac Studio that shows this chat"
        }
      })
      first.closed = true
      hosts.current.lostHost = "Mac Studio"
      mocks.probe.mockResolvedValue([])
      const lost = await provider.invoke(context, "openTabs", {})
      expect(lost.isError).toBe(true)
      expect(JSON.stringify(lost)).toContain(
        "The Codevisor app on Mac Studio disconnected, so this chat's built-in browser tabs were lost."
      )
      expect(await status(provider, context.sessionId)).toMatchObject({
        builtin: {
          state: "unavailable",
          lost: expect.stringContaining("Mac Studio")
        }
      })
      connectTo(macbook, "macbook-tab", false)
      expect(await tabsOf(provider, context.sessionId)).toMatchObject({
        tabs: [{ id: "macbook-tab" }],
        browser: {
          backend: "builtin",
          host: expect.stringContaining("Codevisor on MacBook Pro, in the background")
        }
      })
      expect(mocks.launch).not.toHaveBeenCalled()
    } finally {
      await provider.close()
      rmSync(directory, { recursive: true, force: true })
    }
  })

  it("fails every call with the reason, and never runs headless, when no Mac app can open the chat", async () => {
    const directory = mkdtempSync(join(tmpdir(), "clientless-browser-"))
    const { provider } = builtinProvider(directory)
    const reason =
      "The Codevisor app on MacBook Pro did not respond. Check that Mac for a blocking dialog."
    mocks.connect.mockResolvedValue({
      reason,
      probes: answers([macbook, "unresponsive"])
    })
    mocks.probe.mockResolvedValue(answers([macbook, "unresponsive"]))
    mocks.launch.mockResolvedValue({ connection: connection("headless-tab") })
    const context = { sessionId: "fixture" }
    try {
      expect(
        browserResultValue(await provider.invoke(context, "use_backend", { backend: "builtin" }))
      ).toMatchObject({
        selected: "builtin",
        builtin: {
          state: "unavailable",
          visibleToUser: false,
          reason: expect.stringContaining(reason),
          macs: [
            {
              name: "MacBook Pro",
              state: expect.stringContaining("not responding")
            }
          ]
        }
      })
      for (const tool of ["openTabs", "openTabs"]) {
        const refused = await provider.invoke(context, tool, {})
        expect(refused.isError).toBe(true)
        expect(JSON.stringify(refused)).toContain(
          "The built-in browser can't be reached, so nothing ran."
        )
        expect(JSON.stringify(refused)).toContain(reason)
      }
      expect(mocks.connect).toHaveBeenCalledTimes(2)
      expect(mocks.launch).not.toHaveBeenCalled()
    } finally {
      await provider.close()
      rmSync(directory, { recursive: true, force: true })
    }
  })

  it("fails clearly when the Mac app breaks before its browser starts", async () => {
    const directory = mkdtempSync(join(tmpdir(), "native-browser-setup-"))
    const { provider } = builtinProvider(directory)
    const native = connectTo(studio, "native-tab")
    native.send.mockRejectedValueOnce(Error("app closed during setup"))
    try {
      await provider.invoke({ sessionId: "fixture" }, "use_backend", {
        backend: "builtin"
      })
      const failed = await provider.invoke({ sessionId: "fixture" }, "openTabs", {})
      expect(failed.isError).toBe(true)
      expect(JSON.stringify(failed)).toContain(
        "The Codevisor app on Mac Studio didn't start its built-in browser."
      )
      expect(native.close).toHaveBeenCalledOnce()
      expect(mocks.launch).not.toHaveBeenCalled()
    } finally {
      await provider.close()
      rmSync(directory, { recursive: true, force: true })
    }
  })

  it("moves to the Mac whose window shows the chat at the next response, and fails once none answers", async () => {
    const directory = mkdtempSync(join(tmpdir(), "builtin-reroute-"))
    const { provider } = builtinProvider(directory)
    const context = { sessionId: "fixture" }
    const background = connectTo(macbook, "macbook-tab", false)
    try {
      await provider.invoke(context, "use_backend", { backend: "builtin" })
      await tabsOf(provider, context.sessionId)
      await provider.invoke(context, "js", { code: "var retained = 7" })

      mocks.probe.mockResolvedValue(answers([macbook, "showing"], [studio, "available"]))
      await provider.beginTurn(context.sessionId, { clientPlatform: "macos" })
      expect(await tabsOf(provider, context.sessionId)).toMatchObject({
        browser: {
          host: expect.stringContaining("Codevisor window on MacBook Pro")
        }
      })
      expect(browserResultValue(await provider.invoke(context, "js", { code: "retained" }))).toBe(7)
      expect(mocks.connect).toHaveBeenCalledOnce()

      mocks.probe.mockResolvedValue(answers([studio, "focused"], [macbook, "available"]))
      expect(await status(provider, context.sessionId)).toMatchObject({
        builtin: { host: expect.stringContaining("Codevisor on MacBook Pro, in the background") }
      })
      const shown = connectTo(studio, "studio-tab")
      expect(await tabsOf(provider, context.sessionId)).toMatchObject({
        browser: { host: expect.stringContaining("MacBook Pro") }
      })
      await provider.beginTurn(context.sessionId)
      expect(await status(provider, context.sessionId)).toMatchObject({
        builtin: { host: expect.stringContaining("Codevisor window on Mac Studio") }
      })
      expect(await tabsOf(provider, context.sessionId)).toMatchObject({
        tabs: [{ id: "studio-tab" }],
        browser: {
          host: expect.stringContaining("Codevisor window on Mac Studio")
        }
      })
      expect(background.close).toHaveBeenCalledOnce()
      expect(shown.close).not.toHaveBeenCalled()
      expect(
        browserResultValue(await provider.invoke(context, "js", { code: "typeof retained" }))
      ).toBe("undefined")

      mocks.probe.mockResolvedValue(answers([studio, "unresponsive"]))
      expect(await status(provider, context.sessionId)).toMatchObject({
        builtin: { state: "unavailable", macs: [{ name: "Mac Studio" }] }
      })
      const reason = "The Codevisor app on Mac Studio did not respond."
      mocks.connect.mockResolvedValue({ reason, probes: answers([studio, "unresponsive"]) })
      await provider.beginTurn(context.sessionId)
      const refused = await provider.invoke(context, "openTabs", {})
      expect(refused.isError).toBe(true)
      expect(JSON.stringify(refused)).toContain(reason)
      expect(shown.close).toHaveBeenCalledOnce()
      expect(mocks.launch).not.toHaveBeenCalled()
    } finally {
      await provider.close()
      rmSync(directory, { recursive: true, force: true })
    }
  })

  it("detaches a completed native session without closing the user's app or pages", async () => {
    const directory = mkdtempSync(join(tmpdir(), "native-browser-detach-"))
    const { provider } = builtinProvider(directory)
    const native = connectTo(studio, "native-tab")
    try {
      await provider.invoke({ sessionId: "fixture" }, "use_backend", {
        backend: "builtin"
      })
      await provider.invoke({ sessionId: "fixture" }, "openTabs", {})
      await provider.closeSession?.("fixture")
      expect(native.close).toHaveBeenCalledOnce()
      expect(
        native.send.mock.calls.filter(
          ([method]) => method === "Browser.close" || method === "Target.closeTarget"
        )
      ).toHaveLength(0)
      await provider.invoke({ sessionId: "fixture" }, "use_backend", {
        backend: "builtin"
      })
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
