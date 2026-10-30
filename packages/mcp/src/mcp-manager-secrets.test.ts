import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { makeDatabase } from "@codevisor/db"
import { afterEach, describe, expect, it, vi } from "vitest"

import {
  unavailableBrowserProvider,
  unavailableComputerProvider
} from "./mcp-automation-builtins.js"
import { makeMcpManagerCore } from "./mcp-manager-core.js"
import { makeMcpReplicationOperations } from "./mcp-manager-replication.js"
import {
  cleanupMcpManagerTests,
  connectionStateSettles,
  run,
  directories,
  databases,
  managers,
  testManager,
  TEST_BASE_URL
} from "./mcp-manager-test-support.js"
import { makeMcpManager } from "./mcp-manager.js"
import { bundleWithAccess, memoryOAuthVault } from "./mcp-oauth-vault-test-support.js"
import { decryptSecrets } from "./mcp-secret-store.js"

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
      enabled: true,
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
    const enabling = await manager.update(disconnected.id, { enabled: true })
    expect(enabling.enabled).toBe(true)
    expect(await connectionStateSettles(manager, disconnected.id, "error")).toBe("error")

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
    expect(() =>
      makeMcpManager({ db, dataDir: invalidKeyDirectory, baseUrl: TEST_BASE_URL })
    ).toThrow("Invalid MCP secret key")

    vi.stubEnv("CODEVISOR_MCP_SECRET_KEY", "invalid")
    expect(() =>
      makeMcpManager({ db, dataDir: invalidKeyDirectory, baseUrl: TEST_BASE_URL })
    ).toThrow("must be 32 bytes")
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
    const configuredManager = makeMcpManager({
      db: configuredDb,
      dataDir: configuredKeyDirectory,
      baseUrl: TEST_BASE_URL
    })
    managers.push(configuredManager)
    const sealed = await configuredManager.create({
      authType: "bearer",
      bearerToken: "configured-token",
      enabled: false,
      name: "Configured key",
      transport: "http",
      url: "https://configured.example.com/mcp"
    })
    const stored = await run(configuredDb.getMcpServer(sealed.id))
    expect(decryptSecrets(Buffer.alloc(32, 7), stored?.secretCipher)).toMatchObject({
      bearerToken: "configured-token"
    })
    expect(existsSync(join(configuredKeyDirectory, "mcp-secret-key"))).toBe(false)

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
    await manager.update(stdio.id, {
      env: { A: "changed", B: "discarded", C: "3" },
      removeEnv: ["B"]
    })
    expect(await manager.staticSecrets(stdio.id)).toEqual({ env: { A: "changed", C: "3" } })
    await manager.update(stdio.id, { removeEnv: ["A", "C"] })
    expect(await manager.staticSecrets(stdio.id)).toEqual({})
    await manager.update(stdio.id, { env: { D: "4" } })
    expect(await manager.staticSecrets(stdio.id)).toEqual({ env: { D: "4" } })
    expect(await manager.staticSecrets(bare.id)).toEqual({})
    await manager.update(full.id, { bearerToken: "" })
    expect((await manager.staticSecrets(full.id)).bearerToken).toBeUndefined()
  })

  it("exposes and adopts the synced OAuth credential reference", async () => {
    const shared = memoryOAuthVault()
    const { manager } = await testManager({ serverId: "test", oauthVault: shared.vault })
    const server = await manager.create({
      authType: "oauth",
      enabled: false,
      name: "OAuth Sync",
      transport: "http",
      url: "https://oauth-sync.example.com/mcp"
    })
    const plain = await manager.create({
      authType: "none",
      enabled: false,
      name: "Plain",
      transport: "http",
      url: "https://plain.example.com/mcp"
    })
    expect(await manager.oauthCredential(server.id)).toBeUndefined()
    expect(await manager.oauthCredential(plain.id)).toBeUndefined()

    const credential = shared.seed(bundleWithAccess("at-1"))
    await manager.setOAuthCredential(server.id, credential)
    await manager.setOAuthCredential(server.id, { ...credential })
    expect(await manager.oauthCredential(server.id)).toEqual(credential)

    await manager.setOAuthCredential(server.id, null)
    expect(await manager.oauthCredential(server.id)).toBeNull()
    expect((await manager.list()).find((entry) => entry.id === server.id)).toMatchObject({
      connectionState: "needsAuthorization",
      detail: "OAuth Sync was signed out on another of your machines. Authorize it again."
    })
  })

  it("keeps newer credentials when a write starts from an older snapshot", async () => {
    const shared = memoryOAuthVault()
    const { manager } = await testManager({ serverId: "test", oauthVault: shared.vault })
    const server = await manager.create({
      authType: "oauth",
      enabled: false,
      name: "Snapshot",
      transport: "http",
      url: "https://snapshot.example.com/mcp"
    })
    const first = shared.seed(bundleWithAccess("at-1"))
    const second = shared.seed(bundleWithAccess("at-2"))
    await manager.setOAuthCredential(server.id, first)
    const editing = manager.update(server.id, { headers: { "X-Team": "core" } })
    await manager.setOAuthCredential(server.id, second)
    await editing

    expect(await manager.staticSecrets(server.id)).toEqual({ headers: { "X-Team": "core" } })
    expect(await manager.oauthCredential(server.id)).toEqual(second)
  })

  it("subscribes to the rotation source until unsubscribed", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-mcp-rotation-"))
    directories.push(directory)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const core = makeMcpManagerCore({
      db,
      dataDir: directory,
      baseUrl: TEST_BASE_URL,
      makeBrowserProvider: () => unavailableBrowserProvider("Not used in this test"),
      makeComputerProvider: () => unavailableComputerProvider("Not used in this test")
    })
    const { subscribeCredentialsRotated } = makeMcpReplicationOperations(core, {
      adoptSyncedCredential: vi.fn(async () => undefined),
      migrateLegacyGrant: vi.fn(async () => undefined)
    })
    const listener = vi.fn()
    const unsubscribe = subscribeCredentialsRotated(listener)
    core.emitCredentialsRotated("oauth-server")
    expect(listener).toHaveBeenCalledExactlyOnceWith("oauth-server")
    unsubscribe()
    core.emitCredentialsRotated("oauth-server")
    expect(listener).toHaveBeenCalledOnce()
  })
})
