import { makeDatabase } from "@codevisor/db"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { makeMcpManager } from "./mcp-manager.js"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  cleanupMcpManagerTests,
  run,
  directories,
  databases,
  managers,
  testManager
} from "./mcp-manager-test-support.js"

afterEach(cleanupMcpManagerTests)

describe("MCP manager secrets and replication", () => {
  it("rejects transport-specific configuration before persisting it", async () => {
    const { db, manager } = await testManager()
    const create = (overrides: Record<string, unknown>) =>
      manager.create({ name: "Invalid", transport: "stdio", command: "mcp", ...overrides })

    await expect(create({ command: undefined })).rejects.toThrow("requires a command")
    await expect(create({ command: " " })).rejects.toThrow("requires a command")
    await expect(create({ headers: { Authorization: "secret" } })).rejects.toThrow(
      "only supported for HTTP"
    )
    await expect(create({ authType: "oauth" })).rejects.toThrow(
      "Authorization is only supported for HTTP"
    )
    await expect(create({ bearerToken: "secret" })).rejects.toThrow(
      "Authorization credentials are only supported for HTTP"
    )
    await expect(manager.create({ name: "Invalid", transport: "http" })).rejects.toThrow(
      "requires a URL"
    )
    await expect(
      manager.create({ name: "Invalid", transport: "http", url: "file:///tmp/mcp" })
    ).rejects.toThrow("must use HTTP or HTTPS")
    await expect(
      manager.create({ name: "Invalid", transport: "http", url: "https://example.test", env: {} })
    ).rejects.toThrow("only supported for stdio")
    await expect(manager.connect("missing-mcp")).rejects.toThrow("MCP server not found")

    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("{}", { headers: { "content-type": "application/json" } }))
    )
    expect((await manager.detectAuth("https://mcp.api")).suggestedName).toBe("Mcp")

    const oauthConfigured = await manager.create({
      authType: "oauth",
      name: "OAuth configured",
      oauthClientId: "client-id",
      oauthClientSecret: "client-secret",
      oauthScope: "read",
      transport: "http",
      url: "https://example.test/mcp"
    })
    expect(oauthConfigured).toMatchObject({
      authType: "oauth",
      connectionState: "needsAuthorization",
      enabled: false,
      oauthScope: "read"
    })
    await manager.remove(oauthConfigured.id)

    const disconnected = await manager.create({
      authType: "none",
      command: "codevisor-missing-mcp",
      enabled: false,
      name: "Disconnected",
      transport: "stdio"
    })
    const failed = await manager.update(disconnected.id, { enabled: true })
    expect(failed.connectionState).toBe("error")

    await run(
      db.saveMcpServer({
        authType: "none",
        connectionState: "disconnected",
        enabled: false,
        name: "No secrets",
        toolCount: 0,
        transport: "stdio"
      })
    )
    expect((await manager.list()).some((server) => server.name === "No secrets")).toBe(true)

    const invalidKeyDirectory = mkdtempSync(join(tmpdir(), "codevisor-invalid-mcp-key-"))
    directories.push(invalidKeyDirectory)
    writeFileSync(join(invalidKeyDirectory, "mcp-secret-key"), "short")
    expect(() => makeMcpManager({ db, dataDir: invalidKeyDirectory })).toThrow(
      "Invalid MCP secret key"
    )

    vi.stubEnv("CODEVISOR_MCP_SECRET_KEY", "invalid")
    expect(() => makeMcpManager({ db, dataDir: invalidKeyDirectory })).toThrow("must be 32 bytes")
    vi.stubEnv("CODEVISOR_MCP_SECRET_KEY", Buffer.alloc(32, 7).toString("base64"))
    const configuredKeyDirectory = join(invalidKeyDirectory, "configured")
    mkdirSync(configuredKeyDirectory)
    const configuredDb = await run(
      makeDatabase({
        filename: join(configuredKeyDirectory, "codevisor.sqlite"),
        serverId: "configured-key"
      })
    )
    databases.push(configuredDb)
    const configuredManager = makeMcpManager({ db: configuredDb, dataDir: configuredKeyDirectory })
    managers.push(configuredManager)
    expect(await configuredManager.list()).toBeDefined()

    await run(
      db.saveMcpServer({
        authType: "none",
        connectionState: "disconnected",
        enabled: false,
        name: "Invalid secrets",
        secretCipher: "bad",
        toolCount: 0,
        transport: "stdio"
      })
    )
    await expect(manager.list()).rejects.toThrow("Invalid encrypted MCP credentials")
  })

  it("exposes static secrets for replication, normalizing empty bearers", async () => {
    const { manager } = await testManager()
    const full = await manager.create({
      authType: "bearer",
      bearerToken: "tok-1",
      enabled: false,
      headers: { "X-Org": "851" },
      name: "Full",
      transport: "http",
      url: "https://full.example.com/mcp"
    })
    const stdio = await manager.create({
      command: "echo",
      enabled: false,
      env: { B: "2", A: "1" },
      name: "Stdio",
      transport: "stdio"
    })
    const bare = await manager.create({
      authType: "none",
      enabled: false,
      name: "Bare",
      transport: "http",
      url: "https://bare.example.com/mcp"
    })

    expect(await manager.staticSecrets(full.id)).toEqual({
      bearerToken: "tok-1",
      headers: { "X-Org": "851" }
    })
    expect(await manager.staticSecrets(stdio.id)).toEqual({ env: { B: "2", A: "1" } })
    // A bare server has nothing, and a cleared bearer normalizes to absent.
    expect(await manager.staticSecrets(bare.id)).toEqual({})
    await manager.update(full.id, { bearerToken: "" })
    expect((await manager.staticSecrets(full.id)).bearerToken).toBeUndefined()
  })

  it("owns, exports, imports, and demotes OAuth material for replication", async () => {
    const { manager } = await testManager(undefined, { serverId: "test" })
    const server = await manager.create({
      authType: "oauth",
      enabled: false,
      name: "OAuth Sync",
      transport: "http",
      url: "https://oauth-sync.example.com/mcp"
    })

    // No tokens yet (and non-oauth servers never participate at all).
    expect(await manager.oauthSyncState(server.id)).toBeUndefined()
    const plain = await manager.create({
      authType: "none",
      enabled: false,
      name: "Plain",
      transport: "http",
      url: "https://plain.example.com/mcp"
    })
    expect(await manager.oauthSyncState(plain.id)).toBeUndefined()

    // Importing material with OURSELVES as owner models an authorize here
    // (test manager's serverId is "test"): the sync state is exposed.
    const material = JSON.stringify({
      tokens: { access_token: "at-1", refresh_token: "rt-1", token_type: "bearer" },
      tokensSavedAt: 1_111
    })
    await manager.importOAuthMaterial(server.id, { owner: "test", material })
    const owned = await manager.oauthSyncState(server.id)
    expect(owned?.owner).toBe("test")
    expect(owned?.rotatedAtMs).toBe(1_111)
    expect(JSON.parse(owned?.material ?? "{}").tokens.access_token).toBe("at-1")

    // Another machine rotates and takes ownership: we become a mirror —
    // the material stays visible (with its owner) but is not ours.
    const rotated = JSON.stringify({
      tokens: { access_token: "at-2", refresh_token: "rt-2", token_type: "bearer" },
      tokensSavedAt: 2_222
    })
    await manager.importOAuthMaterial(server.id, { owner: "other-machine", material: rotated })
    const mirrored = await manager.oauthSyncState(server.id)
    expect(mirrored?.owner).toBe("other-machine")
    expect(JSON.parse(mirrored?.material ?? "{}").tokens.access_token).toBe("at-2")

    // Identical re-imports and junk are silent no-ops.
    await manager.importOAuthMaterial(server.id, { owner: "other-machine", material: rotated })
    await manager.importOAuthMaterial(server.id, { owner: "other-machine", material: "not json" })
    await manager.importOAuthMaterial(server.id, { owner: "other-machine", material: "null" })
    expect((await manager.oauthSyncState(server.id))?.owner).toBe("other-machine")

    // Rotation listeners register and unregister cleanly.
    const seen: Array<string> = []
    const unsubscribe = manager.subscribeCredentialsRotated((id) => seen.push(id))
    unsubscribe()
    expect(seen).toEqual([])
  })
})
