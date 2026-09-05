import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { afterEach, describe, expect, it, vi } from "vitest"
import { makeMcpManager } from "./mcp-manager.js"
import {
  cleanupMcpManagerTests,
  connectionStateSettles,
  managers,
  run,
  testManager,
  workingUpstream
} from "./mcp-manager-test-support.js"

afterEach(cleanupMcpManagerTests)

const initializeCount = (requests: ReadonlyArray<{ method: string }>): number =>
  requests.filter((request) => request.method === "initialize").length

describe("MCP manager lifecycle", () => {
  it("keeps a live connection across changes the transport does not depend on", async () => {
    const upstream = await workingUpstream()
    const { manager } = await testManager()
    const created = await manager.create({
      authType: "none",
      name: "Tracker",
      transport: "http",
      url: upstream.url
    })
    expect(created).toMatchObject({ connectionState: "connected", toolCount: 2 })
    const handshakes = initializeCount(upstream.requests)

    // A rename (what a synced definition most often carries) and a no-op
    // enable flip leave the upstream untouched.
    expect(await manager.update(created.id, { name: "Renamed" })).toMatchObject({
      connectionState: "connected",
      name: "Renamed",
      toolCount: 2
    })
    expect(await manager.update(created.id, { enabled: true })).toMatchObject({
      connectionState: "connected",
      toolCount: 2
    })
    expect(initializeCount(upstream.requests)).toBe(handshakes)

    // Disabling closes; re-enabling answers before the handshake settles.
    expect(await manager.update(created.id, { enabled: false })).toMatchObject({
      connectionState: "disconnected",
      enabled: false,
      toolCount: 0
    })
    const reenabled = await manager.update(created.id, { enabled: true })
    expect(reenabled.enabled).toBe(true)
    expect(await connectionStateSettles(manager, created.id, "connected")).toBe("connected")
    expect(initializeCount(upstream.requests)).toBe(handshakes + 1)

    // A transport-affecting edit reconnects.
    await manager.update(created.id, { headers: { "X-Trace": "1" } })
    expect(await connectionStateSettles(manager, created.id, "connected")).toBe("connected")
    expect(initializeCount(upstream.requests)).toBe(handshakes + 2)
  })

  it("drops a connection that settles after the server was switched off", async () => {
    const upstream = await workingUpstream()
    const { manager } = await testManager()
    const created = await manager.create({
      authType: "none",
      enabled: false,
      name: "Tracker",
      transport: "http",
      url: upstream.url
    })
    const entered = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    const closed = Promise.withResolvers<void>()
    const connect = Client.prototype.connect
    const close = Client.prototype.close
    vi.spyOn(Client.prototype, "connect").mockImplementation(async function (
      this: Client,
      ...args
    ) {
      entered.resolve()
      await release.promise
      return connect.apply(this, args)
    })
    vi.spyOn(Client.prototype, "close").mockImplementation(async function (this: Client) {
      await close.call(this)
      closed.resolve()
    })
    await manager.update(created.id, { enabled: true })
    await entered.promise
    const disabled = await manager.update(created.id, { enabled: false })
    expect(disabled).toMatchObject({ enabled: false })
    release.resolve()
    await closed.promise
    expect((await manager.list()).find((server) => server.id === created.id)).toMatchObject({
      enabled: false,
      connectionState: "disconnected",
      toolCount: 0
    })
    await expect(manager.tools(created.id)).rejects.toThrow("is disabled")
  })

  it("publishes visible record changes to subscribers", async () => {
    const upstream = await workingUpstream()
    const { manager } = await testManager()
    const seen: string[] = []
    const unsubscribe = manager.subscribeServersChanged((id) => seen.push(id))

    const created = await manager.create({
      authType: "none",
      name: "Tracker",
      transport: "http",
      url: upstream.url
    })
    expect(seen).toContain(created.id)
    seen.length = 0

    await manager.update(created.id, { enabled: false })
    expect(seen).toContain(created.id)
    seen.length = 0

    // Nothing visible changed: no notification.
    await manager.update(created.id, { enabled: false })
    expect(seen).toEqual([])

    await manager.remove(created.id)
    expect(seen).toContain(created.id)
    seen.length = 0

    unsubscribe()
    await manager.create({ authType: "none", name: "Quiet", transport: "http", url: upstream.url })
    expect(seen).toEqual([])
  })

  it("keeps an OAuth server's enabled wish while it needs authorization", async () => {
    const { manager } = await testManager()
    const created = await manager.create({
      authType: "oauth",
      name: "Sentry",
      transport: "http",
      url: "https://mcp.example.test/mcp"
    })
    expect(created).toMatchObject({ enabled: true, connectionState: "needsAuthorization" })

    // Enabling an unauthorized server is honored as a wish and reported as
    // needing authorization — never silently flipped back off.
    expect(await manager.update(created.id, { enabled: true })).toMatchObject({
      enabled: true,
      connectionState: "needsAuthorization"
    })
    expect(await manager.update(created.id, { oauthScope: "read" })).toMatchObject({
      enabled: true,
      connectionState: "needsAuthorization"
    })
    // No credentials means no network attempt: the refusal is immediate.
    await expect(manager.tools(created.id)).rejects.toThrow("needs authorization")
    expect((await manager.list()).find((server) => server.id === created.id)).toMatchObject({
      enabled: true,
      connectionState: "needsAuthorization"
    })
  })

  it("adopts refresh ownership of tokens recorded under a former identity", async () => {
    const { manager } = await testManager(undefined, { serverId: "test" })
    const legacy = await manager.create({
      authType: "oauth",
      name: "Legacy",
      transport: "http",
      url: "https://legacy.example.test/mcp"
    })
    const foreign = await manager.create({
      authType: "oauth",
      name: "Foreign",
      transport: "http",
      url: "https://foreign.example.test/mcp"
    })
    const material = JSON.stringify({
      tokens: { access_token: "at", refresh_token: "rt", token_type: "bearer" },
      tokensSavedAt: 10
    })
    await manager.importOAuthMaterial(legacy.id, { owner: "local", material })
    await manager.importOAuthMaterial(foreign.id, { owner: "other-machine", material })

    // Adopting our own id is a no-op; a foreign owner is left alone; the
    // legacy owner's tokens become ours to refresh (test manager id: "test").
    expect(await manager.adoptOAuthOwnership("test")).toEqual([])
    expect(await manager.adoptOAuthOwnership("local")).toEqual([legacy.id])
    expect((await manager.oauthSyncState(legacy.id))?.owner).toBe("test")
    expect((await manager.oauthSyncState(foreign.id))?.owner).toBe("other-machine")
    expect(await manager.adoptOAuthOwnership("local")).toEqual([])
  })

  it("connects a mirror with imported OAuth material, on import and on boot", async () => {
    const upstream = await workingUpstream()
    const { db, directory, manager } = await testManager(undefined, { serverId: "mirror" })
    const created = await manager.create({
      authType: "oauth",
      name: "Sentry",
      transport: "http",
      url: upstream.url
    })
    expect(created.connectionState).toBe("needsAuthorization")
    const material = JSON.stringify({
      tokens: { access_token: "at", refresh_token: "rt", token_type: "bearer", expires_in: 3600 },
      tokensSavedAt: 10
    })
    // The owner's material arrives: the mirror tries it straight away —
    // unless the server is switched off here, which leaves it alone.
    const idle = await manager.create({
      authType: "oauth",
      enabled: false,
      name: "Idle",
      transport: "http",
      url: upstream.url
    })
    await manager.importOAuthMaterial(idle.id, { owner: "owner-machine", material })
    await manager.importOAuthMaterial(created.id, { owner: "owner-machine", material })
    expect(await connectionStateSettles(manager, created.id, "connected")).toBe("connected")
    expect((await manager.list()).find((server) => server.id === idle.id)?.connectionState).toBe(
      "needsAuthorization"
    )
    expect(upstream.requests.some((request) => request.headers.authorization === "Bearer at")).toBe(
      true
    )

    // A record left at "needs authorization" by an older build (tokens
    // present, never tried) heals when the manager boots.
    const stored = (await run(db.getMcpServer(created.id)))!
    await run(
      db.saveMcpServer({
        id: stored.id,
        name: stored.name,
        kind: stored.kind,
        transport: stored.transport,
        url: upstream.url,
        args: stored.args,
        enabled: stored.enabled,
        authType: stored.authType,
        connectionState: "needsAuthorization",
        toolCount: 0,
        ...(stored.secretCipher === undefined ? {} : { secretCipher: stored.secretCipher })
      })
    )
    await manager.close()
    managers.splice(managers.indexOf(manager), 1)
    const rebooted = makeMcpManager({ db, dataDir: directory, serverId: "mirror" })
    managers.push(rebooted)
    expect(await connectionStateSettles(rebooted, created.id, "connected")).toBe("connected")
  })
})
