import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { afterEach, describe, expect, it, vi } from "vitest"

import {
  cleanupMcpManagerTests,
  connectionStateSettles,
  managers,
  run,
  testManager,
  workingUpstream,
  TEST_BASE_URL
} from "./mcp-manager-test-support.js"
import { makeMcpManager } from "./mcp-manager.js"
import {
  bundleWithAccess,
  memoryOAuthVault,
  seedLegacyOAuth
} from "./mcp-oauth-vault-test-support.js"

afterEach(cleanupMcpManagerTests)

const initializeCount = (requests: ReadonlyArray<{ method: string }>): number =>
  requests.filter((request) => request.method === "initialize").length

const legacyOAuth = (owner: string) => ({
  refreshOwner: owner,
  tokens: { access_token: "at", refresh_token: "rt", token_type: "bearer", expires_in: 3600 },
  tokensSavedAt: 10,
  clientInformation: { client_id: "registered", redirect_uris: ["http://127.0.0.1:1/cb"] },
  redirectUrl: "http://127.0.0.1:1/cb",
  discoveryState: { authorizationServerUrl: "https://auth.legacy.example.test" }
})

describe("MCP manager lifecycle", () => {
  it("an old tools handshake cannot replace a newly configured upstream", async () => {
    const oldServer = await workingUpstream()
    const newServer = await workingUpstream()
    const { manager, db } = await testManager()
    const entered = Promise.withResolvers<void>()
    const release = Promise.withResolvers<void>()
    vi.spyOn(Client.prototype, "listTools").mockImplementationOnce(async () => {
      entered.resolve()
      await release.promise
      return { tools: [{ name: "obsolete", inputSchema: { type: "object" as const } }] }
    })
    const old = manager.create({
      authType: "none",
      name: "Replace",
      transport: "http",
      url: oldServer.url
    })
    try {
      await entered.promise
      const created = (await run(db.listMcpServers)).find((server) => server.name === "Replace")!
      await manager.update(created.id, { url: newServer.url })
      await connectionStateSettles(manager, created.id, "connected")
      release.resolve()
      await old
      expect((await manager.tools(created.id)).map((tool) => tool.name)).not.toContain("obsolete")
      expect((await manager.list()).find((server) => server.id === created.id)?.url).toBe(
        newServer.url
      )
    } finally {
      release.resolve()
      await old.catch(() => undefined)
    }
  })
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

    expect(await manager.update(created.id, { enabled: false })).toMatchObject({
      connectionState: "disconnected",
      enabled: false,
      toolCount: 0
    })
    const reenabled = await manager.update(created.id, { enabled: true })
    expect(reenabled.enabled).toBe(true)
    expect(await connectionStateSettles(manager, created.id, "connected")).toBe("connected")
    expect(initializeCount(upstream.requests)).toBe(handshakes + 1)

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
    // oxlint-disable-next-line typescript/unbound-method
    const connect = Client.prototype.connect
    // oxlint-disable-next-line typescript/unbound-method
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

  it("returns a server created to connect in the background before its handshake finishes", async () => {
    const upstream = await workingUpstream()
    const { manager } = await testManager()
    const release = Promise.withResolvers<void>()
    // oxlint-disable-next-line typescript/unbound-method
    const connect = Client.prototype.connect
    vi.spyOn(Client.prototype, "connect").mockImplementation(async function (
      this: Client,
      ...args
    ) {
      await release.promise
      return connect.apply(this, args)
    })

    const created = await manager.create(
      { authType: "none", name: "Tracker", transport: "http", url: upstream.url },
      { connectInBackground: true }
    )
    release.resolve()

    expect(created).toMatchObject({ connectionState: "disconnected", toolCount: 0 })
    expect(await connectionStateSettles(manager, created.id, "connected")).toBe("connected")
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

    await manager.update(created.id, { enabled: false })
    expect(seen).toEqual([])

    await manager.remove(created.id)
    expect(seen).toContain(created.id)
    seen.length = 0

    const awaitingSignIn = await manager.create({
      authType: "oauth",
      name: "Sentry",
      transport: "http",
      url: "https://mcp.example.test/mcp"
    })
    expect(seen).toEqual([awaitingSignIn.id])
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

    expect(await manager.update(created.id, { enabled: true })).toMatchObject({
      enabled: true,
      connectionState: "needsAuthorization"
    })
    expect(await manager.update(created.id, { oauthScope: "read" })).toMatchObject({
      enabled: true,
      connectionState: "needsAuthorization"
    })
    await expect(manager.tools(created.id)).rejects.toThrow("needs authorization")
    expect((await manager.list()).find((server) => server.id === created.id)).toMatchObject({
      enabled: true,
      connectionState: "needsAuthorization"
    })
  })

  it("moves its own legacy sign-in into the shared vault and leaves another machine's mirror", async () => {
    const { vault } = memoryOAuthVault()
    const { db, directory, manager } = await testManager({ serverId: "test", oauthVault: vault })
    const legacy = await manager.create({
      authType: "oauth",
      enabled: false,
      name: "Legacy",
      transport: "http",
      url: "https://legacy.example.test/mcp"
    })
    const foreign = await manager.create({
      authType: "oauth",
      enabled: false,
      name: "Foreign",
      transport: "http",
      url: "https://foreign.example.test/mcp"
    })
    await seedLegacyOAuth(db, directory, legacy.id, legacyOAuth("local"))
    await seedLegacyOAuth(db, directory, foreign.id, legacyOAuth("other-machine"))

    expect(await manager.adoptOAuthOwnership("test")).toEqual([])
    expect(await manager.adoptOAuthOwnership("local")).toEqual([legacy.id])
    expect(await manager.oauthCredential(legacy.id)).toEqual(
      await vault.create.mock.results[0]?.value
    )
    expect(vault.create).toHaveBeenCalledExactlyOnceWith(
      expect.objectContaining({
        accessToken: "at",
        refreshToken: "rt",
        expiresAt: 3_600_010,
        credential: expect.objectContaining({
          authorizationServerUrl: "https://auth.legacy.example.test",
          client: expect.objectContaining({ client_id: "registered" })
        })
      })
    )
    expect(await manager.oauthCredential(foreign.id)).toBeUndefined()
    expect(await manager.adoptOAuthOwnership("local")).toEqual([])
  })

  it("connects with a synced credential, on adoption and on boot", async () => {
    const upstream = await workingUpstream()
    const shared = memoryOAuthVault()
    const { db, directory, manager } = await testManager({
      serverId: "mirror",
      oauthVault: shared.vault
    })
    const created = await manager.create({
      authType: "oauth",
      name: "Sentry",
      transport: "http",
      url: upstream.url
    })
    expect(created.connectionState).toBe("needsAuthorization")
    const idle = await manager.create({
      authType: "oauth",
      enabled: false,
      name: "Idle",
      transport: "http",
      url: upstream.url
    })
    const credential = shared.seed(bundleWithAccess("at"))
    await manager.setOAuthCredential(idle.id, credential)
    await manager.setOAuthCredential(created.id, credential)
    expect(await connectionStateSettles(manager, created.id, "connected")).toBe("connected")
    expect((await manager.list()).find((server) => server.id === idle.id)?.connectionState).toBe(
      "needsAuthorization"
    )
    expect(upstream.requests.some((request) => request.headers.authorization === "Bearer at")).toBe(
      true
    )

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
    const rebooted = makeMcpManager({
      db,
      dataDir: directory,
      baseUrl: TEST_BASE_URL,
      serverId: "mirror",
      oauthVault: shared.vault
    })
    managers.push(rebooted)
    expect(await connectionStateSettles(rebooted, created.id, "connected")).toBe("connected")
  })
})
