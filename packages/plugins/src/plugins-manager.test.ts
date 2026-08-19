import { describe, expect, it } from "vitest"
import { WebSocket } from "ws"
import { makePluginsManager } from "./plugins-manager.js"
import {
  cleanups,
  exampleManifest,
  makeDir,
  makeManager,
  makeOuterServer,
  writePlugin
} from "./test-support.js"

describe("plugin listing", () => {
  it("lists installed plugins with runtime state and pane metadata", async () => {
    const { manager } = makeManager()
    const list = await manager.list()
    expect(list.plugins).toHaveLength(1)
    expect(list.plugins[0]?.id).toBe("owner.example")
    expect(list.plugins[0]?.description).toBe("Example plugin")
    expect(list.plugins[0]?.state).toBe("stopped")
    expect(list.plugins[0]?.panes[0]?.type).toBe("main")
  })

  it("omits absent descriptions and filters other-platform plugins", async () => {
    const { manager, root } = makeManager()
    writePlugin(root, "elsewhere", {
      ...exampleManifest,
      description: undefined,
      id: "owner.elsewhere",
      platforms: ["never-os"]
    })
    const list = await manager.list()
    expect(list.plugins.map((plugin) => plugin.id)).toEqual(["owner.example"])
    const other = makeManager({ platform: "never-os" })
    writePlugin(other.root, "elsewhere", {
      ...exampleManifest,
      description: undefined,
      id: "owner.elsewhere",
      platforms: ["never-os"]
    })
    // Plugins without a platforms allowlist run everywhere; the allowlisted
    // one appears only when the platform matches.
    const otherList = await other.manager.list()
    expect(otherList.plugins.map((plugin) => plugin.id)).toEqual([
      "owner.elsewhere",
      "owner.example"
    ])
    expect(otherList.plugins[0]?.description).toBeUndefined()
  })

  it("gets a single plugin and 404s unknown ids", async () => {
    const { manager } = makeManager()
    expect((await manager.get("owner.example")).name).toBe("Example")
    await expect(manager.get("owner.unknown")).rejects.toThrow(/not installed/)
  })
})

describe("pane tokens", () => {
  it("issues a pane URL carrying the token and pane id", async () => {
    const { manager } = makeManager()
    const issued = await manager.issuePaneToken("owner.example", "pane-1", {
      cwd: "/tmp/project",
      paneType: "main",
      themeMode: "dark",
      workspaceId: "w1"
    })
    expect(issued.path).toContain("/v1/plugins/owner.example/app/panes/main/?")
    expect(issued.path).toContain("codevisorPaneToken=")
    expect(issued.path).toContain("paneId=pane-1")
    expect(Date.parse(issued.expiresAt)).toBeGreaterThan(Date.now())
  })

  it("rejects unknown plugins and pane types", async () => {
    const { manager } = makeManager()
    await expect(
      manager.issuePaneToken("owner.unknown", "pane-1", { paneType: "main" })
    ).rejects.toThrow(/not installed/)
    await expect(
      manager.issuePaneToken("owner.example", "pane-1", { paneType: "bogus" })
    ).rejects.toThrow(/no pane type/)
  })
})

describe("pane proxy", () => {
  it("ignores non-proxy URLs", async () => {
    const { manager } = makeManager()
    const outer = await makeOuterServer(manager)
    const response = await fetch(`${outer.origin}/v1/plugins/owner.example`)
    expect(response.status).toBe(404)
  })

  it("redirects /app to /app/ preserving the query", async () => {
    const { manager } = makeManager()
    const outer = await makeOuterServer(manager)
    const response = await fetch(`${outer.origin}/v1/plugins/owner.example/app?x=1`, {
      redirect: "manual"
    })
    expect(response.status).toBe(308)
    expect(response.headers.get("location")).toBe("/v1/plugins/owner.example/app/?x=1")
  })

  it("rejects unauthenticated pane requests", async () => {
    const { manager } = makeManager()
    const outer = await makeOuterServer(manager)
    const response = await fetch(`${outer.origin}/v1/plugins/owner.example/app/panes/main/`)
    expect(response.status).toBe(404)
    const bogus = await fetch(
      `${outer.origin}/v1/plugins/owner.example/app/panes/main/?codevisorPaneToken=bogus`
    )
    expect(bogus.status).toBe(404)
    const bogusCookie = await fetch(`${outer.origin}/v1/plugins/owner.example/app/panes/main/`, {
      headers: { cookie: "codevisor-plugin-owner-example=stale" }
    })
    expect(bogusCookie.status).toBe(404)
  })

  it("404s proxy requests for plugins that are not installed", async () => {
    const { manager } = makeManager()
    const outer = await makeOuterServer(manager)
    const response = await fetch(`${outer.origin}/v1/plugins/owner.ghost/app/panes/main/`)
    expect(response.status).toBe(404)
  })

  it("exchanges the pane token for a scoped cookie session", async () => {
    const { fake, manager } = makeManager()
    const outer = await makeOuterServer(manager)
    const issued = await manager.issuePaneToken("owner.example", "pane-1", {
      cwd: "/tmp/project",
      paneType: "main",
      workspaceId: "w1"
    })
    const first = await fetch(`${outer.origin}${issued.path}&extra=1`)
    expect(first.status).toBe(200)
    expect(await first.text()).toContain("pane")
    const setCookie = first.headers.get("set-cookie") ?? ""
    expect(setCookie).toContain("codevisor-plugin-owner-example=")
    expect(setCookie).toContain("Path=/v1/plugins/owner.example/")
    // The plugin saw the pane id and extra params, never the token; context
    // arrived as a signed header.
    const seen = fake.requests[0]
    expect(seen?.path).toContain("paneId=pane-1")
    expect(seen?.path).toContain("extra=1")
    expect(seen?.path).not.toContain("codevisorPaneToken")
    expect(seen?.headers["x-codevisor-context"]).toBeDefined()
    expect(seen?.headers["x-codevisor-context-signature"]).toBeDefined()
    expect(seen?.headers["authorization"]).toBeUndefined()
    const context = JSON.parse(
      Buffer.from(String(seen?.headers["x-codevisor-context"]), "base64").toString("utf8")
    ) as Record<string, unknown>
    expect(context["cwd"]).toBe("/tmp/project")
    expect(context["workspaceId"]).toBe("w1")

    // Subresources authenticate by cookie alone, with our cookie stripped
    // from what the plugin sees.
    const cookie = setCookie.split(";")[0] ?? ""
    const asset = await fetch(`${outer.origin}/v1/plugins/owner.example/app/panes/main/asset.js`, {
      headers: { cookie: `${cookie}; plugincookie=existing` }
    })
    expect(asset.status).toBe(200)
    expect(asset.headers.get("set-cookie")).toBeNull()
    const assetSeen = fake.requests.at(-1)
    expect(assetSeen?.headers["cookie"]).toBe("plugincookie=existing")
  })

  it("appends the session cookie to plugin set-cookie responses", async () => {
    const { manager } = makeManager()
    const outer = await makeOuterServer(manager)
    const issued = await manager.issuePaneToken("owner.example", "pane-1", { paneType: "main" })
    const token = new URL(`http://x${issued.path}`).searchParams.get("codevisorPaneToken")
    const response = await fetch(
      `${outer.origin}/v1/plugins/owner.example/app/panes/main/cookies?codevisorPaneToken=${token}`
    )
    const cookies = response.headers.getSetCookie()
    expect(cookies.some((value) => value.startsWith("plugincookie=1"))).toBe(true)
    expect(cookies.some((value) => value.startsWith("codevisor-plugin-owner-example="))).toBe(true)
  })

  it("returns 502 when the plugin process is unreachable", async () => {
    const { fake, manager } = makeManager()
    const outer = await makeOuterServer(manager)
    const issued = await manager.issuePaneToken("owner.example", "pane-1", { paneType: "main" })
    expect((await fetch(`${outer.origin}${issued.path}`)).status).toBe(200)
    fake.stop()
    const cookieToken = new URL(`http://x${issued.path}`).searchParams.get("codevisorPaneToken")
    const response = await fetch(
      `${outer.origin}/v1/plugins/owner.example/app/panes/main/?codevisorPaneToken=${cookieToken}`
    )
    expect(response.status).toBe(502)
    const body = (await response.json()) as { code?: string }
    expect(body.code).toBe("pluginUnreachable")
  })

  it("kicks the supervisor on 502 so the next request relaunches the plugin", async () => {
    const { fake, manager } = makeManager({ backoffBaseMs: 0 })
    const outer = await makeOuterServer(manager)
    const issued = await manager.issuePaneToken("owner.example", "pane-1", { paneType: "main" })
    expect((await fetch(`${outer.origin}${issued.path}`)).status).toBe(200)
    // The process died behind the supervisor's back: the runtime still says
    // running, but the port is dead.
    fake.stop()
    const token = new URL(`http://x${issued.path}`).searchParams.get("codevisorPaneToken")
    const paneUrl = `${outer.origin}/v1/plugins/owner.example/app/panes/main/?codevisorPaneToken=${token}`
    expect((await fetch(paneUrl)).status).toBe(502)
    // The 502 marked the plugin stopped, so this request relaunches instead
    // of forwarding into the dead port again.
    expect((await fetch(paneUrl)).status).toBe(200)
    expect((await manager.get("owner.example")).state).toBe("running")
  })

  it("times out hung plugin requests with a 504", async () => {
    const { manager } = makeManager({ proxyTimeoutMs: 300 })
    const outer = await makeOuterServer(manager)
    const issued = await manager.issuePaneToken("owner.example", "pane-1", { paneType: "main" })
    const token = new URL(`http://x${issued.path}`).searchParams.get("codevisorPaneToken")
    const response = await fetch(
      `${outer.origin}/v1/plugins/owner.example/app/panes/main/never?codevisorPaneToken=${token}`
    )
    expect(response.status).toBe(504)
  })
})

describe("pane websockets", () => {
  const openSocket = (url: string): Promise<WebSocket> =>
    new Promise((resolve, reject) => {
      const socket = new WebSocket(url)
      cleanups.push(() => socket.close())
      socket.on("open", () => resolve(socket))
      socket.on("error", reject)
    })

  it("splices authenticated websocket upgrades through to the plugin", async () => {
    const { fake, manager } = makeManager()
    const outer = await makeOuterServer(manager)
    const issued = await manager.issuePaneToken("owner.example", "pane-1", { paneType: "main" })
    const token = new URL(`http://x${issued.path}`).searchParams.get("codevisorPaneToken")
    const socket = await openSocket(
      `ws://127.0.0.1:${outer.port}/v1/plugins/owner.example/app/live?codevisorPaneToken=${token}&room=7`
    )
    const reply = await new Promise<string>((resolve) => {
      socket.on("message", (data) => resolve(String(data)))
      socket.send("hello")
    })
    expect(reply).toBe("echo:hello")
    const upgradeSeen = fake.requests.at(-1)
    expect(upgradeSeen?.path).toBe("/live?room=7")
    expect(upgradeSeen?.headers["x-codevisor-context"]).toBeDefined()
  })

  it("accepts loopback upgrades without a token (relay path)", async () => {
    const { fake, manager } = makeManager()
    const outer = await makeOuterServer(manager)
    const socket = await openSocket(
      `ws://127.0.0.1:${outer.port}/v1/plugins/owner.example/app/live`
    )
    const reply = await new Promise<string>((resolve) => {
      socket.on("message", (data) => resolve(String(data)))
      socket.send("ping")
    })
    expect(reply).toBe("echo:ping")
    expect(fake.requests.at(-1)?.headers["x-codevisor-context"]).toBeUndefined()
  })

  it("rejects non-loopback upgrades without pane auth", async () => {
    const { manager } = makeManager({ isLocalhost: () => false })
    const outer = await makeOuterServer(manager)
    await expect(
      openSocket(`ws://127.0.0.1:${outer.port}/v1/plugins/owner.example/app/live`)
    ).rejects.toThrow(/401/)
  })

  it("rejects upgrades for unknown plugins", async () => {
    const { manager } = makeManager()
    const outer = await makeOuterServer(manager)
    await expect(
      openSocket(`ws://127.0.0.1:${outer.port}/v1/plugins/owner.ghost/app/live`)
    ).rejects.toThrow(/502/)
  })

  it("splices upgrades addressed to the bare /app root", async () => {
    const { fake, manager } = makeManager()
    const outer = await makeOuterServer(manager)
    const socket = await openSocket(`ws://127.0.0.1:${outer.port}/v1/plugins/owner.example/app`)
    const reply = await new Promise<string>((resolve) => {
      socket.on("message", (data) => resolve(String(data)))
      socket.send("root")
    })
    expect(reply).toBe("echo:root")
    expect(fake.requests.at(-1)?.path).toBe("/")
  })

  it("ignores non-plugin upgrade paths", async () => {
    const { manager } = makeManager()
    const outer = await makeOuterServer(manager)
    await expect(openSocket(`ws://127.0.0.1:${outer.port}/v1/events/socket`)).rejects.toThrow()
  })
})

describe("defaults", () => {
  it("constructs with only a data dir, resolving the root from the environment", async () => {
    const root = makeDir("codevisor-plugins-env-root-")
    writePlugin(root, "example", exampleManifest)
    process.env["CODEVISOR_PLUGINS_ROOT"] = root
    try {
      const manager = makePluginsManager({ dataDir: makeDir("codevisor-plugins-env-data-") })
      cleanups.push(() => manager.close())
      const list = await manager.list()
      expect(list.plugins.map((plugin) => plugin.id)).toEqual(["owner.example"])
    } finally {
      delete process.env["CODEVISOR_PLUGINS_ROOT"]
    }
  })
})

describe("close", () => {
  it("stops supervised plugin processes", async () => {
    const { manager } = makeManager()
    const outer = await makeOuterServer(manager)
    const issued = await manager.issuePaneToken("owner.example", "pane-1", { paneType: "main" })
    expect((await fetch(`${outer.origin}${issued.path}`)).status).toBe(200)
    manager.close()
    expect((await manager.get("owner.example")).state).toBe("stopped")
  })
})
