import { runInNewContext } from "node:vm"

import { describe, expect, it } from "vitest"

import type { BridgeBoot } from "./plugin-app-bridge.js"
import { appShellHtml, policyMeta, scriptJson, withPreamble } from "./plugin-app-shell.js"

const boot: BridgeBoot = {
  protocolVersion: "2026-01-26",
  hostInfo: { name: "Codevisor", version: "1.0.0" },
  hostCapabilities: {},
  hostContext: { theme: "dark", displayMode: "inline" },
  html: "<p>app</p></script><script>alert(1)</script>",
  allow: "clipboard-write",
  token: "session-token",
  endpoints: { toolsCall: "/call", resourcesRead: "/read", modelContext: "/context" }
}

const shellScript = (html: string): string => {
  const match = /<script>([\s\S]*)<\/script>/.exec(html)
  if (match === null) throw new Error("The shell has no script")
  return match[1]!
}

const shellReply = async (navigator: unknown, method: string, params: unknown) => {
  const replied = Promise.withResolvers<unknown>()
  const posted: Array<unknown> = []
  const contentWindow = { postMessage: (message: unknown) => replied.resolve(message) }
  let handler: ((event: unknown) => void) | undefined
  const window = {
    addEventListener: (_type: string, listener: (event: unknown) => void) => {
      handler = listener
    },
    location: { pathname: "/v1/plugins/apps/view-1" },
    navigator,
    webkit: {
      messageHandlers: {
        codevisorApp: { postMessage: (message: unknown) => posted.push(message) }
      }
    }
  }
  const html = appShellHtml({ ...boot, viewId: "view-1" })
  runInNewContext(shellScript(html), {
    window,
    document: { getElementById: () => ({ contentWindow, srcdoc: "", setAttribute: () => {} }) }
  })
  handler?.({
    source: contentWindow,
    data: {
      jsonrpc: "2.0",
      id: 1,
      method,
      params
    }
  })
  return { reply: await replied.promise, posted }
}

const tourIt = { role: "user", content: { type: "text", text: "Tour it" } }

const sentMessage = (navigator: unknown) => shellReply(navigator, "ui/message", tourIt)

describe("plugin app shell", () => {
  it("adds the app's preamble before anything else in its document", () => {
    const meta = `<meta http-equiv="Content-Security-Policy" content="default-src &quot;x&quot; &amp; &lt;">`
    expect(policyMeta('default-src "x" & <')).toBe(meta)
    expect(withPreamble("<html><head lang=en><title>x</title>", "<!--p-->")).toBe(
      "<html><head lang=en><!--p--><title>x</title>"
    )
    expect(withPreamble("<!DOCTYPE html><p>x</p>", "<!--p-->")).toBe(
      "<!DOCTYPE html><!--p--><p>x</p>"
    )
    expect(withPreamble("<p>x</p>", "<!--p-->")).toBe("<!--p--><p>x</p>")
  })

  it("embeds data so it can't close the script", () => {
    expect(scriptJson({ html: "</script>\u2028\u2029" })).toBe(
      '{"html":"\\u003c/script>\\u2028\\u2029"}'
    )
    expect(appShellHtml(boot).match(/<\/script>/g)).toHaveLength(1)
  })

  it("runs the bridge against the page and the native message handler", () => {
    const html = appShellHtml({ ...boot, hostContext: { theme: "light" } })
    const frame = {
      contentWindow: { postMessage: () => undefined },
      srcdoc: "",
      attributes: {} as Record<string, string>,
      setAttribute(name: string, value: string) {
        this.attributes[name] = value
      }
    }
    const posted: Array<unknown> = []
    const opened: Array<unknown> = []
    let handler: ((event: unknown) => void) | undefined
    const window = {
      addEventListener: (_type: string, listener: (event: unknown) => void) => {
        handler = listener
      },
      location: { pathname: "/v1/plugins/apps/view-1" },
      fetch: () => Promise.reject(new Error("offline")),
      open: (...args: Array<unknown>) => opened.push(args),
      webkit: {
        messageHandlers: {
          codevisorApp: { postMessage: (message: unknown) => posted.push(message) }
        }
      }
    }

    runInNewContext(shellScript(html), { window, document: { getElementById: () => frame } })
    handler?.({
      source: frame.contentWindow,
      data: { method: "ui/notifications/size-changed", params: { height: 120 } }
    })

    expect(html).toContain('<html lang="en" style="color-scheme: light">')
    expect(frame.srcdoc).toBe(boot.html)
    expect(frame.attributes).toEqual({ allow: "clipboard-write" })
    expect(posted).toEqual([{ type: "size", height: 120 }])
    expect(opened).toEqual([])
  })

  it("posts an app's chat message only while the page has a user gesture", async () => {
    const idle = await sentMessage({ userActivation: { isActive: false } })
    const legacy = await sentMessage(undefined)
    const tapped = await sentMessage({ userActivation: { isActive: true } })

    for (const refused of [idle, legacy]) {
      expect(refused.reply).toEqual({
        jsonrpc: "2.0",
        id: 1,
        error: { code: -32000, message: "A user gesture is required" }
      })
      expect(refused.posted).toEqual([])
    }
    expect(tapped.reply).toEqual({ jsonrpc: "2.0", id: 1, result: {} })
    expect(tapped.posted).toEqual([{ type: "message", text: "Tour it", viewId: "view-1" }])
  })

  it("tells the native host which display modes the app supports", async () => {
    const declared = await shellReply(undefined, "ui/initialize", {
      appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] }
    })
    const silent = await shellReply(undefined, "ui/initialize", { appCapabilities: {} })

    expect(declared.posted).toEqual([{ type: "appModes", modes: ["inline", "fullscreen"] }])
    expect(declared.reply).toMatchObject({ id: 1, result: { protocolVersion: "2026-01-26" } })
    expect(silent.posted).toEqual([])
  })
})
