import type { PluginsManager, PluginStateEvent } from "@codevisor/plugins"
import { PluginsError } from "@codevisor/plugins"
import { mkdirSync, mkdtempSync } from "node:fs"
import { connect } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import {
  jsonRequest,
  makeServices,
  readSseEvents,
  run,
  runningServers,
  startWithApp,
  tempDirs
} from "../test-support.js"

const pluginSummary = {
  id: "owner.example",
  name: "Example",
  panes: [{ path: "/panes/main/", title: "Main", type: "main" }],
  path: "/tmp/example",
  source: "linked",
  state: "stopped",
  version: "0.1.0"
} as const

const pluginsStub = (
  calls: Array<Array<unknown>>,
  listeners: Array<(event: PluginStateEvent) => void> = []
): PluginsManager => ({
  close: () => calls.push(["close"]),
  discoverRemote: async (request) => {
    calls.push(["discoverRemote", request])
    if (request.source === "ghost/missing") {
      throw new PluginsError("invalid", "No codevisor-plugin.json found in ghost/missing")
    }
    return {
      alreadyInstalled: false,
      description: "Example plugin",
      id: "owner.example",
      installCommand: "bun install",
      name: "Example",
      panes: pluginSummary.panes,
      runCommand: "bun run start",
      version: "0.1.0"
    }
  },
  importRemote: async (request) => {
    calls.push(["importRemote", request])
    if (request.source === "other/taken") {
      throw new PluginsError("conflict", "already provided by dev-checkout")
    }
    return { ...pluginSummary, source: "managed" }
  },
  link: async (request) => {
    calls.push(["link", request])
    if (request.path === "relative/path") {
      throw new PluginsError("invalid", "Plugin link path must be absolute")
    }
    return pluginSummary
  },
  remove: async (pluginId) => {
    calls.push(["remove", pluginId])
    if (pluginId !== "owner.example") {
      throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
    }
    return { plugins: [] }
  },
  get: async (pluginId) => {
    calls.push(["get", pluginId])
    if (pluginId === "owner.conflict") {
      throw new PluginsError("conflict", "conflicting install")
    }
    if (pluginId === "owner.invalid") {
      throw new PluginsError("invalid", "broken manifest")
    }
    if (pluginId === "owner.unavailable") {
      throw new PluginsError("unavailable", "circuit breaker is open")
    }
    if (pluginId !== "owner.example") {
      throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
    }
    return pluginSummary
  },
  handleProxyRequest: async (_request, response, url) => {
    // Mirror the real manager: only proxy-shaped paths are handled here.
    if (!url.pathname.includes("/app/") || url.pathname.endsWith("/unhandled/")) {
      return false
    }
    calls.push(["proxy", url.pathname])
    response.writeHead(200, { "Content-Type": "text/html" })
    response.end("<html>pane</html>")
    return true
  },
  handleUpgrade: async (request, socket) => {
    const url = new URL(request.url ?? "/", "http://127.0.0.1")
    if (url.pathname.endsWith("/unhandled")) {
      return false
    }
    calls.push(["upgrade", url.pathname])
    socket.write("HTTP/1.1 418 Plugin Socket\r\nConnection: close\r\n\r\n")
    socket.destroy()
    return true
  },
  issuePaneToken: async (pluginId, paneId, request) => {
    calls.push(["issuePaneToken", pluginId, paneId, request])
    return {
      expiresAt: new Date().toISOString(),
      path: `/v1/plugins/${pluginId}/app/panes/${request.paneType}/?paneId=${paneId}&codevisorPaneToken=tok`,
      token: "tok"
    }
  },
  list: async () => {
    calls.push(["list"])
    return { plugins: [pluginSummary] }
  },
  restart: async (pluginId) => {
    calls.push(["restart", pluginId])
    if (pluginId !== "owner.example") {
      throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
    }
    return pluginSummary
  },
  subscribe: (listener) => {
    listeners.push(listener)
    return () => calls.push(["unsubscribe"])
  }
})

const rawUpgradeStatus = (url: string, path: string): Promise<string> =>
  new Promise((resolve) => {
    const target = new URL(url)
    const socket = connect({ host: target.hostname, port: Number(target.port) })
    let received = ""
    socket.on("connect", () => {
      socket.write(
        `GET ${path} HTTP/1.1\r\nHost: ${target.host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGVzdA==\r\nSec-WebSocket-Version: 13\r\n\r\n`
      )
    })
    socket.on("data", (chunk) => {
      received += chunk.toString("utf8")
    })
    socket.on("close", () => resolve(received))
    socket.setTimeout(2_000, () => socket.destroy())
  })

/// Seeds a project and a workspace so tests can attach pane records to it.
const seedWorkspaces = async (
  server: Awaited<ReturnType<typeof startWithApp>>,
  workspaceIds: ReadonlyArray<string>
): Promise<void> => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-plugin-route-"))
  tempDirs.push(root)
  const projectFolder = join(root, "project")
  mkdirSync(projectFolder)
  const project = (
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: projectFolder }),
      method: "POST"
    })
  ).body as { readonly id: string }
  await Promise.all(
    workspaceIds.map((workspaceId) =>
      jsonRequest(server, `/v1/workspaces/${workspaceId}`, {
        body: JSON.stringify({ hasCustomName: false, name: workspaceId, projectId: project.id }),
        method: "PUT"
      })
    )
  )
}

const seedPane = async (
  server: Awaited<ReturnType<typeof startWithApp>>,
  workspaceId: string,
  paneId: string,
  providerId: string
): Promise<void> => {
  await jsonRequest(server, `/v1/workspaces/${workspaceId}/panes/${paneId}`, {
    body: JSON.stringify({ paneType: "main", providerId, title: "Pane" }),
    method: "PUT"
  })
}

describe("plugin routes", () => {
  it("501s when the plugins manager is unavailable", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp(services)
    runningServers.push(server)
    expect((await jsonRequest(server, "/v1/plugins")).status).toBe(501)
    // Proxy-shaped paths fall through the pre-auth branch and 501 too.
    expect((await jsonRequest(server, "/v1/plugins/owner.example/app/panes/main/")).status).toBe(
      501
    )
  })

  it("advertises plugins-v1 only when the manager is present", async () => {
    const { services } = await makeServices("server-a")
    const without = await startWithApp(services)
    runningServers.push(without)
    const bare = (await jsonRequest(without, "/v1/info")).body as { features: Array<string> }
    expect(bare.features).not.toContain("plugins-v1")
    const withPlugins = await startWithApp({ ...services, plugins: pluginsStub([]) })
    runningServers.push(withPlugins)
    const info = (await jsonRequest(withPlugins, "/v1/info")).body as { features: Array<string> }
    expect(info.features).toContain("plugins-v1")
  })

  it("lists plugins, fetches details, and issues pane tokens", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<Array<unknown>> = []
    const server = await startWithApp({ ...services, plugins: pluginsStub(calls) })
    runningServers.push(server)

    const list = await jsonRequest(server, "/v1/plugins")
    expect(list.status).toBe(200)
    expect((list.body as { plugins: Array<unknown> }).plugins).toHaveLength(1)

    const detail = await jsonRequest(server, "/v1/plugins/owner.example")
    expect(detail.status).toBe(200)
    expect((detail.body as { id: string }).id).toBe("owner.example")

    const token = await jsonRequest(server, "/v1/plugins/owner.example/panes/pane-1/token", {
      body: JSON.stringify({ cwd: "/tmp", paneType: "main" }),
      method: "POST"
    })
    expect(token.status).toBe(201)
    expect((token.body as { token: string }).token).toBe("tok")
    expect(calls).toContainEqual([
      "issuePaneToken",
      "owner.example",
      "pane-1",
      { cwd: "/tmp", paneType: "main" }
    ])
  })

  it("maps PluginsError codes onto HTTP statuses", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp({ ...services, plugins: pluginsStub([]) })
    runningServers.push(server)
    expect((await jsonRequest(server, "/v1/plugins/owner.ghost")).status).toBe(404)
    expect((await jsonRequest(server, "/v1/plugins/owner.invalid")).status).toBe(400)
    expect((await jsonRequest(server, "/v1/plugins/owner.conflict")).status).toBe(409)
    expect((await jsonRequest(server, "/v1/plugins/owner.unavailable")).status).toBe(503)
  })

  it("restarts a plugin, returns the updated summary, and emits plugin.updated", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<Array<unknown>> = []
    const server = await startWithApp({ ...services, plugins: pluginsStub(calls) })
    runningServers.push(server)
    const live = readSseEvents(server, 1)
    const restarted = await jsonRequest(server, "/v1/plugins/owner.example/restart", {
      method: "POST"
    })
    expect(restarted.status).toBe(200)
    expect((restarted.body as { id: string; state: string }).state).toBe("stopped")
    expect(calls).toContainEqual(["restart", "owner.example"])
    // Open panes reload on plugin.updated (never on plugin.state.updated).
    expect(await live).toContainEqual(
      expect.objectContaining({
        kind: "plugin.updated",
        subjectId: "owner.example",
        payload: expect.objectContaining({ id: "owner.example" })
      })
    )
    expect(
      (await jsonRequest(server, "/v1/plugins/owner.ghost/restart", { method: "POST" })).status
    ).toBe(404)
  })

  it("enriches summaries with the count of open plugin panes", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp({ ...services, plugins: pluginsStub([]) })
    runningServers.push(server)
    await seedWorkspaces(server, ["ws-count"])
    await seedPane(server, "ws-count", "pane-1", "plugin:owner.example")
    await seedPane(server, "ws-count", "pane-2", "plugin:owner.example")
    await seedPane(server, "ws-count", "pane-3", "plugin:owner.other")

    const list = await jsonRequest(server, "/v1/plugins")
    const summaries = (list.body as { plugins: Array<{ openPaneCount: number }> }).plugins
    expect(summaries[0]?.openPaneCount).toBe(2)
    const detail = await jsonRequest(server, "/v1/plugins/owner.example")
    expect((detail.body as { openPaneCount: number }).openPaneCount).toBe(2)
  })

  it("forwards plugin state events into the fanout and unsubscribes on close", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<Array<unknown>> = []
    const listeners: Array<(event: PluginStateEvent) => void> = []
    const server = await startWithApp({ ...services, plugins: pluginsStub(calls, listeners) })
    expect(listeners).toHaveLength(1)
    listeners[0]?.({
      kind: "plugin.state.updated",
      payload: { ...pluginSummary, state: "running" },
      subjectId: "owner.example"
    })
    const events = await readSseEvents(server, 1)
    const event = events[0] as { kind: string; subjectId: string; payload: { state: string } }
    expect(event.kind).toBe("plugin.state.updated")
    expect(event.subjectId).toBe("owner.example")
    expect(event.payload.state).toBe("running")
    await Effect.runPromise(server.close)
    expect(calls).toContainEqual(["unsubscribe"])
  })

  it("discovers a remote source and reports the verbatim commands", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<Array<unknown>> = []
    const server = await startWithApp({ ...services, plugins: pluginsStub(calls) })
    runningServers.push(server)
    const discovered = await jsonRequest(server, "/v1/plugins/discover-remote", {
      body: JSON.stringify({ source: "owner/example" }),
      method: "POST"
    })
    expect(discovered.status).toBe(200)
    expect(discovered.body).toMatchObject({
      alreadyInstalled: false,
      id: "owner.example",
      installCommand: "bun install",
      runCommand: "bun run start"
    })
    expect(calls).toContainEqual(["discoverRemote", { source: "owner/example" }])
    const missing = await jsonRequest(server, "/v1/plugins/discover-remote", {
      body: JSON.stringify({ source: "ghost/missing" }),
      method: "POST"
    })
    expect(missing.status).toBe(400)
  })

  it("imports a remote plugin and links local directories", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<Array<unknown>> = []
    const server = await startWithApp({ ...services, plugins: pluginsStub(calls) })
    runningServers.push(server)
    const live = readSseEvents(server, 2)
    const imported = await jsonRequest(server, "/v1/plugins/import-remote", {
      body: JSON.stringify({ source: "owner/example" }),
      method: "POST"
    })
    expect(imported.status).toBe(201)
    expect((imported.body as { id: string; source: string }).source).toBe("managed")
    expect(calls).toContainEqual(["importRemote", { source: "owner/example" }])
    expect(
      (
        await jsonRequest(server, "/v1/plugins/import-remote", {
          body: JSON.stringify({ source: "other/taken" }),
          method: "POST"
        })
      ).status
    ).toBe(409)

    const linked = await jsonRequest(server, "/v1/plugins/link", {
      body: JSON.stringify({ path: "/tmp/dev-plugin" }),
      method: "POST"
    })
    expect(linked.status).toBe(201)
    expect((linked.body as { id: string }).id).toBe("owner.example")
    expect(calls).toContainEqual(["link", { path: "/tmp/dev-plugin" }])
    // Both install paths change the plugin's code on disk, so both tell
    // clients to reload open panes.
    expect(await live).toEqual([
      expect.objectContaining({
        kind: "plugin.updated",
        subjectId: "owner.example",
        payload: expect.objectContaining({ source: "managed" })
      }),
      expect.objectContaining({
        kind: "plugin.updated",
        subjectId: "owner.example",
        payload: expect.objectContaining({ source: "linked" })
      })
    ])
    expect(
      (
        await jsonRequest(server, "/v1/plugins/link", {
          body: JSON.stringify({ path: "relative/path" }),
          method: "POST"
        })
      ).status
    ).toBe(400)
  })

  it("removes managed plugins and answers with the updated list", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<Array<unknown>> = []
    const server = await startWithApp({ ...services, plugins: pluginsStub(calls) })
    runningServers.push(server)
    const removed = await jsonRequest(server, "/v1/plugins/owner.example", { method: "DELETE" })
    expect(removed.status).toBe(200)
    expect((removed.body as { plugins: Array<unknown> }).plugins).toEqual([])
    expect(calls).toContainEqual(["remove", "owner.example"])
    expect(
      (await jsonRequest(server, "/v1/plugins/owner.ghost", { method: "DELETE" })).status
    ).toBe(404)
  })

  it("uninstalling a plugin deletes its pane records and publishes the closures", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<Array<unknown>> = []
    const server = await startWithApp({ ...services, plugins: pluginsStub(calls) })
    runningServers.push(server)
    // ws-shared: the plugin pane sits next to another pane → plain deletion.
    // ws-lonely: the plugin pane is the workspace's only pane → New Tab.
    await seedWorkspaces(server, ["ws-shared", "ws-lonely"])
    await seedPane(server, "ws-shared", "plugin-pane", "plugin:owner.example")
    await seedPane(server, "ws-shared", "other-pane", "plugin:owner.other")
    await seedPane(server, "ws-lonely", "lonely-pane", "plugin:owner.example")

    const replay = await run(services.db.listEvents(0))
    const live = readSseEvents(server, 2, replay.at(-1)?.id ?? 0)
    const removed = await jsonRequest(server, "/v1/plugins/owner.example", { method: "DELETE" })
    expect(removed.status).toBe(200)
    expect(calls).toContainEqual(["remove", "owner.example"])
    // Same payload shapes as the pane close route: clients close the tabs.
    const events = await live
    expect(events).toContainEqual(
      expect.objectContaining({
        kind: "workspace.pane.deleted",
        subjectId: "plugin-pane",
        payload: { id: "plugin-pane", workspaceId: "ws-shared" }
      })
    )
    expect(events).toContainEqual(
      expect.objectContaining({
        kind: "workspace.pane.updated",
        subjectId: "lonely-pane",
        payload: expect.objectContaining({ id: "lonely-pane", paneType: "new-tab" })
      })
    )
    const panes = (await jsonRequest(server, "/v1/workspace-panes")).body as Array<{
      id: string
      providerId: string
    }>
    expect(panes.some((pane) => pane.providerId === "plugin:owner.example")).toBe(false)
    // Other plugins' panes are untouched.
    expect(panes.some((pane) => pane.id === "other-pane")).toBe(true)
  })

  it("404s unmatched plugin paths and methods", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp({ ...services, plugins: pluginsStub([]) })
    runningServers.push(server)
    expect((await jsonRequest(server, "/v1/plugins/owner.example", { method: "PUT" })).status).toBe(
      404
    )
    expect((await jsonRequest(server, "/v1/plugins/owner.example/panes/pane-1/token")).status).toBe(
      404
    )
  })

  it("routes pane proxy traffic before bearer authorization", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<Array<unknown>> = []
    const server = await startWithApp(
      { ...services, plugins: pluginsStub(calls) },
      undefined,
      // Token-required auth: pane traffic must still flow with no bearer.
      { auth: { allowLocalhostWithoutAuth: false, requireBearerToken: true } }
    )
    runningServers.push(server)
    const response = await fetch(`${server.url}/v1/plugins/owner.example/app/panes/main/`)
    expect(response.status).toBe(200)
    expect(await response.text()).toContain("pane")
    expect(calls).toContainEqual(["proxy", "/v1/plugins/owner.example/app/panes/main/"])
    // Paths the manager declines fall through to authorized routing (401
    // here, because this server requires a bearer token).
    const unhandled = await fetch(`${server.url}/v1/plugins/owner.example/app/unhandled/`)
    expect(unhandled.status).toBe(401)
  })

  it("hands plugin upgrade requests to the manager before authorization", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<Array<unknown>> = []
    const server = await startWithApp({ ...services, plugins: pluginsStub(calls) })
    runningServers.push(server)
    const handled = await rawUpgradeStatus(server.url, "/v1/plugins/owner.example/app/live")
    expect(handled).toContain("418 Plugin Socket")
    expect(calls).toContainEqual(["upgrade", "/v1/plugins/owner.example/app/live"])
    // Unhandled plugin paths fall through to the normal upgrade chain, which
    // destroys unknown sockets without a response.
    const unhandled = await rawUpgradeStatus(server.url, "/v1/plugins/owner.example/app/unhandled")
    expect(unhandled).toBe("")
  })

  it("destroys plugin upgrade requests when the manager is unavailable", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp(services)
    runningServers.push(server)
    const response = await rawUpgradeStatus(server.url, "/v1/plugins/owner.example/app/live")
    expect(response).toBe("")
  })
})
