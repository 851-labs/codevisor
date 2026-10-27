import { join } from "node:path"

import type { McpServer } from "@codevisor/api"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import { makeMcpManager, type McpManager } from "@codevisor/mcp"
import Database from "better-sqlite3"
import { describe, expect, it } from "vitest"

import { run } from "../test-support.js"
import { MCPS_SYNC_NAMESPACE, reconcileMcps } from "./config-sync.js"
import {
  fakeOAuthMcpServer,
  listenOn,
  machineVault,
  manualOAuthClock,
  sharedCoordinator,
  tempDirectory
} from "./mcp-oauth-test-support.js"

const serverId = "studio"

interface Machine {
  readonly db: CodevisorDatabaseService
  readonly mcp: McpManager
}

const boot = async (
  dataDir: string,
  vault: ReturnType<typeof machineVault>,
  clock: ReturnType<typeof manualOAuthClock>
): Promise<Machine> => {
  const db = await run(makeDatabase({ filename: join(dataDir, "codevisor.sqlite"), serverId }))
  const mcp = makeMcpManager({
    db,
    dataDir,
    baseUrl: "http://127.0.0.1:43210",
    serverId,
    oauthClock: clock,
    oauthVault: vault
  })
  mcp.setBaseUrl(await listenOn(mcp.handleGatewayRequest))
  return { db, mcp }
}

const shutDown = async ({ db, mcp }: Machine): Promise<void> => {
  await mcp.close()
  await run(db.close)
}

const rewindToBeforePlugins = (dataDir: string): void => {
  const sqlite = new Database(join(dataDir, "codevisor.sqlite"))
  try {
    sqlite.exec(`
      drop table plugin_event_deliveries;
      drop table plugin_events;
      drop table plugin_event_cursors;
      drop table plugin_event_subscriptions;
      drop table plugin_app_contexts;
      alter table mcp_servers drop column catalog_id;
      alter table mcp_servers drop column catalog_version;
      alter table mcp_servers drop column capabilities;
      alter table prompt_queue_items drop column attribution;
      alter table chat_items drop column attribution;
      delete from schema_migrations where id = 82;
    `)
  } finally {
    sqlite.close()
  }
}

const userServers = async (mcp: McpManager): Promise<ReadonlyArray<McpServer>> =>
  (await mcp.list()).filter((server) => server.kind === "managed")

const definition = (server: McpServer) => ({
  id: server.id,
  name: server.name,
  transport: server.transport,
  url: server.url,
  command: server.command,
  args: server.args,
  enabled: server.enabled,
  authType: server.authType,
  headerNames: server.headerNames,
  environmentNames: server.environmentNames,
  catalogId: server.catalogId
})

const secretsOf = async (mcp: McpManager, servers: ReadonlyArray<McpServer>) =>
  Promise.all(servers.map(async (server) => [server.name, await mcp.staticSecrets(server.id)]))

describe("upgrading user-added MCP servers to plugins", () => {
  it("keeps names, config, secrets, vault sign-ins and sync state without signing in again", async () => {
    const clock = manualOAuthClock()
    const coordinator = sharedCoordinator(clock)
    const fake = await fakeOAuthMcpServer(clock)
    const dataDir = await tempDirectory()
    const vault = machineVault(coordinator, serverId, clock, dataDir)

    const before = await boot(dataDir, vault, clock)
    const tracker = await before.mcp.create({
      authType: "oauth",
      enabled: true,
      name: "Tracker",
      transport: "http",
      url: fake.url
    })
    const { code, state } = fake.approve(await before.mcp.beginOAuth(tracker.id))
    await before.mcp.finishOAuth(state, code)
    await before.mcp.create({
      name: "Docs",
      transport: "http",
      url: "https://docs.example.com/mcp",
      authType: "bearer",
      bearerToken: "docs-token",
      headers: { "x-team": "core" },
      enabled: false
    })
    await before.mcp.create({
      name: "Local",
      transport: "stdio",
      command: "local-mcp",
      args: ["--root", "/tmp"],
      env: { API_KEY: "local-secret" },
      enabled: false
    })
    await reconcileMcps({ db: before.db, mcp: before.mcp, serverId })
    const servers = await userServers(before.mcp)
    const expected = {
      servers: servers.map(definition),
      secrets: await secretsOf(before.mcp, servers),
      credential: await before.mcp.oauthCredential(tracker.id),
      replica: await run(before.db.getSyncEntries(MCPS_SYNC_NAMESPACE)),
      applied: await run(before.db.getSyncEntries("local.mcps-applied"))
    }
    expect(expected.credential).toEqual({ id: expect.any(String), key: expect.any(String) })
    await shutDown(before)

    rewindToBeforePlugins(dataDir)
    const after = await boot(dataDir, vault, clock)
    try {
      const upgraded = await userServers(after.mcp)
      expect(upgraded.map(definition)).toEqual(expected.servers)
      expect(await secretsOf(after.mcp, upgraded)).toEqual(expected.secrets)
      expect(await after.mcp.oauthCredential(tracker.id)).toEqual(expected.credential)

      const resynced = await reconcileMcps({ db: after.db, mcp: after.mcp, serverId })
      expect(resynced.status).toEqual({ published: [], applied: [], removed: [], renamed: [] })
      expect(await run(after.db.getSyncEntries(MCPS_SYNC_NAMESPACE))).toEqual(expected.replica)
      expect(await run(after.db.getSyncEntries("local.mcps-applied"))).toEqual(expected.applied)

      const connected = await after.mcp.connect(tracker.id)
      expect(connected.connectionState).toBe("connected")
      expect(fake.grants()).toHaveLength(1)
      expect(await run(after.db.migrate)).toEqual([])
    } finally {
      await shutDown(after)
    }
  })
})
