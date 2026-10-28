import { runInNewContext } from "node:vm"

import { describe, expect, it } from "vitest"

import {
  capturedView,
  launch,
  secured,
  shell,
  startRelay,
  type Secured
} from "../plugins/apps/plugin-app-route-support.js"
import { zillowPlugin } from "../plugins/apps/plugin-app-test-support.js"
import { jsonRequest } from "../test-support.js"

interface BridgeReply {
  readonly id?: unknown
  readonly result?: unknown
  readonly error?: unknown
}

const isReply = (value: unknown): value is BridgeReply =>
  typeof value === "object" && value !== null

const shellScript = (html: string): string => {
  const match = /<script>([\s\S]*)<\/script>/.exec(html)
  if (match === null) throw new Error("The shell has no script")
  return match[1]!
}

const openedPage = (html: string, documentUrl: URL) => {
  const fetched: Array<string> = []
  const replies = new Map<unknown, PromiseWithResolvers<BridgeReply>>()
  let listener: ((event: unknown) => void) | undefined
  const contentWindow = {
    postMessage: (message: unknown) => {
      if (isReply(message)) replies.get(message.id)?.resolve(message)
    }
  }
  const window = {
    location: {
      pathname: documentUrl.pathname,
      href: documentUrl.href,
      search: documentUrl.search
    },
    setTimeout: () => 0,
    addEventListener: (_type: string, handler: (event: unknown) => void) => {
      listener = handler
    },
    fetch: (url: string, init: RequestInit) => {
      fetched.push(url)
      return fetch(new URL(url, documentUrl), init)
    },
    open: () => undefined
  }
  runInNewContext(shellScript(html), {
    window,
    URL,
    document: { getElementById: () => ({ contentWindow, srcdoc: "", setAttribute: () => {} }) }
  })
  const request = (id: number, method: string, params: Record<string, unknown>) => {
    const reply = Promise.withResolvers<BridgeReply>()
    replies.set(id, reply)
    listener?.({ source: contentWindow, data: { jsonrpc: "2.0", id, method, params } })
    return reply.promise
  }
  return { fetched, request }
}

const firstScript = (html: string): string => {
  const match = /<script>([\s\S]*?)<\/script>/.exec(html)
  if (match === null) throw new Error("The app has no script")
  return match[1]!
}

const openedApp = (shellHtml: string, appHtml: string, documentUrl: URL) => {
  let shellListener: ((event: unknown) => void) | undefined
  let appListener: ((event: unknown) => void) | undefined
  const appWindow: Record<string, unknown> = {}
  const contentWindow = {
    postMessage: (message: unknown) => appListener?.({ source: parent, data: message })
  }
  const parent = {
    postMessage: (message: unknown) => shellListener?.({ source: contentWindow, data: message })
  }
  runInNewContext(shellScript(shellHtml), {
    URL,
    window: {
      location: {
        pathname: documentUrl.pathname,
        href: documentUrl.href,
        search: documentUrl.search
      },
      setTimeout: () => 0,
      addEventListener: (_type: string, handler: (event: unknown) => void) => {
        shellListener = handler
      },
      fetch: (url: string, init: RequestInit) => fetch(new URL(url, documentUrl), init),
      open: () => undefined
    },
    document: { getElementById: () => ({ contentWindow, srcdoc: "", setAttribute: () => {} }) }
  })
  Object.assign(appWindow, {
    parent,
    addEventListener: (_type: string, handler: (event: unknown) => void) => {
      appListener = handler
    },
    dispatchEvent: () => true
  })
  runInNewContext(firstScript(appHtml), { window: appWindow, CustomEvent: Object })
  return { appWindow, parent }
}

const throughRelay = (setup: Secured, relayUrl: string): Secured => ({
  ...setup,
  server: { ...setup.server, url: relayUrl }
})

const machineLocal = (setup: Secured): ReadonlyArray<string> => [
  new URL(setup.server.url).host,
  new URL(setup.plugin.url).host
]

describe("plugin apps through a client relay", () => {
  it("serves a view and proxies its host calls using only relative paths", async () => {
    const setup = await secured()
    const viewId = await capturedView(setup)
    const relay = await startRelay(setup.server.url)
    const client = throughRelay(setup, relay.url)

    const url = await launch(client, `/v1/plugins/apps/${viewId}/token`)
    const loaded = await shell(client, `${url}&theme=dark`)
    const page = openedPage(loaded.html, new URL(`${relay.url}${url}`))
    const initialized = await page.request(1, "ui/initialize", {})
    const called = await page.request(2, "tools/call", {
      name: "refresh",
      arguments: { all: true }
    })
    const read = await page.request(3, "resources/read", { uri: "ui://grafana/data.json" })
    const context = await page.request(4, "ui/update-model-context", {
      structuredContent: { a: 1 }
    })

    expect(url).toMatch(/^\/v1\/plugins\/apps\/[0-9a-f-]{36}\?token=/)
    for (const local of machineLocal(setup)) {
      expect(url).not.toContain(local)
      expect(loaded.html).not.toContain(local)
      expect(loaded.policy).not.toContain(local)
    }
    expect(initialized.result).toMatchObject({ hostContext: { theme: "dark" } })
    expect(called.result).toMatchObject({
      structuredContent: { params: { name: "refresh", arguments: { all: true } } }
    })
    expect(read.result).toMatchObject({ contents: [{ uri: "ui://grafana/data.json" }] })
    expect(context.result).toEqual({})
    expect(page.fetched).toEqual([
      loaded.boot!.endpoints.toolsCall,
      loaded.boot!.endpoints.resourcesRead,
      loaded.boot!.endpoints.modelContext
    ])
    expect(relay.requests.map(({ path }) => path.split("?")[0])).toEqual([
      `/v1/plugins/apps/${viewId}/token`,
      `/v1/plugins/apps/${viewId}`,
      `/v1/plugins/apps/${viewId}/tools/call`,
      `/v1/plugins/apps/${viewId}/resources/read`,
      `/v1/plugins/apps/${viewId}/model-context`
    ])
    expect(relay.requests.some(({ cookie }) => cookie)).toBe(false)
    expect(setup.plugin.requests).toContainEqual({
      method: "tools/call",
      params: { name: "refresh", arguments: { all: true } }
    })
  })

  it("accepts the view's token from the shell's header alone", async () => {
    const setup = await secured()
    const viewId = await capturedView(setup)
    const relay = await startRelay(setup.server.url)
    const client = throughRelay(setup, relay.url)
    const { boot } = await shell(client, await launch(client, `/v1/plugins/apps/${viewId}/token`))
    const token = new URL(boot!.endpoints.toolsCall, relay.url).searchParams.get("token")!

    const called = await jsonRequest(client.server, `/v1/plugins/apps/${viewId}/tools/call`, {
      method: "POST",
      headers: { "x-codevisor-app-token": token },
      body: JSON.stringify({ name: "refresh" })
    })

    expect(called.status).toBe(200)
  })

  it("serves a pane and proxies its host calls through the relay", async () => {
    const setup = await secured()
    const relay = await startRelay(setup.server.url)
    const client = throughRelay(setup, relay.url)

    const url = await launch(client, `/v1/plugins/${setup.serverId}/panes/dashboard/token`)
    const loaded = await shell(client, url)
    const page = openedPage(loaded.html, new URL(`${relay.url}${url}`))
    const called = await page.request(1, "tools/call", { name: "refresh" })

    expect(url).toMatch(/^\/v1\/plugins\/panes\/[\w-]+\.[\w-]+\/$/)
    expect(called.result).toMatchObject({ content: [{ type: "text", text: "done" }] })
    expect(page.fetched.every((path) => path.startsWith("/v1/plugins/panes/"))).toBe(true)
    expect(relay.requests.some(({ cookie }) => cookie)).toBe(false)
  })

  it("serves Apps SDK widgets their globals and window.openai calls alongside ui/* calls", async () => {
    const setup = await secured(zillowPlugin(), "Zillow")
    const viewId = await capturedView(
      setup,
      "zillow_property_search",
      "{ request: { displayLimit: 2 } }"
    )
    const relay = await startRelay(setup.server.url)
    const client = throughRelay(setup, relay.url)
    const url = await launch(client, `/v1/plugins/apps/${viewId}/token`)
    const loaded = await shell(client, url)

    const app = openedApp(loaded.html, loaded.boot!.html, new URL(`${relay.url}${url}`))
    const openai = isReply(app.appWindow.openai) ? app.appWindow.openai : {}
    const callTool = Reflect.get(openai, "callTool")
    const called: unknown = await Reflect.apply(callTool, openai, [
      "get_zestimate",
      { address: "1 Main St" }
    ])

    expect(openai).toMatchObject({
      toolInput: { request: { displayLimit: 2 } },
      toolOutput: { resultCounts: { totalMatchingCount: 155, displayResultsCount: 100 } },
      toolResponseMetadata: { "zillow.com/data": { widget: "search" } }
    })
    expect(called).toMatchObject({ content: [{ type: "text", text: "done" }] })
    expect(setup.plugin.requests).toContainEqual({
      method: "tools/call",
      params: { name: "get_zestimate", arguments: { address: "1 Main St" } }
    })
    expect(loaded.boot?.toolResult).toMatchObject({
      structuredContent: { resultCounts: { totalMatchingCount: 155 } },
      _meta: { "zillow.com/data": { widget: "search" } }
    })
    expect(loaded.policy).toContain("https://maps.googleapis.com")
  })
})
