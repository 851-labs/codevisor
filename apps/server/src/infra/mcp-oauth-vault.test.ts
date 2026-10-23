import { readdir, readFile } from "node:fs/promises"
import { join } from "node:path"

import type { McpManager } from "@codevisor/mcp"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { CallToolResultSchema } from "@modelcontextprotocol/sdk/types.js"
import { describe, expect, it, onTestFinished } from "vitest"

import { gatewayTransport } from "../routes/gateway-test-support.js"
import { makeServices, run } from "../test-support.js"
import { MCPS_SYNC_NAMESPACE, reconcileMcps } from "./config-sync.js"
import {
  type FakeOAuthMcpServer,
  fakeOAuthMcpServer,
  listenOn,
  machineVault,
  type ManualOAuthClock,
  manualOAuthClock,
  seedLegacyMcpOAuth,
  sharedCoordinator,
  tempDirectory
} from "./mcp-oauth-test-support.js"
import { mcpCredentialVault } from "./shared-account-storage.js"

const HOUR = 60 * 60_000

interface Fleet {
  readonly clock: ManualOAuthClock
  readonly coordinator: ReturnType<typeof sharedCoordinator>
  readonly fake: FakeOAuthMcpServer
}

const fleet = async (): Promise<Fleet> => {
  const clock = manualOAuthClock()
  return { clock, coordinator: sharedCoordinator(clock), fake: await fakeOAuthMcpServer(clock) }
}

const machine = async (
  { clock, coordinator }: Fleet,
  serverId: string,
  vault?: ReturnType<typeof mcpCredentialVault>
) => {
  const { services } = await makeServices(serverId, {
    oauthClock: clock,
    oauthVault: vault ?? machineVault(coordinator, serverId, clock, await tempDirectory())
  })
  const manager = services.mcp
  manager.setBaseUrl(await listenOn(manager.handleGatewayRequest))
  const project = await run(services.db.createProject({ folderPath: `/tmp/${serverId}` }))
  const trackerId = async () => {
    const found = (await manager.list()).find((server) => server.name === "Tracker")
    if (found === undefined) throw new Error(`Tracker is missing on ${serverId}`)
    return found.id
  }
  const chat = async () => {
    const session = await run(
      services.db.createSession({ harnessId: "codex", projectId: project.id, title: "Chat" })
    )
    const issued = await manager.issueGateway(session.id, project.id)
    const client = new Client({ name: "mcp-vault-test", version: "1" })
    await client.connect(gatewayTransport(issued))
    onTestFinished(() => client.close())
    const id = await trackerId()
    return async (): Promise<string> =>
      JSON.stringify(
        CallToolResultSchema.parse(
          await client.callTool({
            name: "execute",
            arguments: {
              description: "Ask the tracker who we are",
              code: `async () => machines.current.tools["${id}.whoami"]({})`
            }
          })
        ).content
      )
  }
  return {
    serverId,
    manager,
    services,
    chat,
    trackerId,
    sync: { db: services.db, mcp: manager, serverId }
  }
}

type Machine = Awaited<ReturnType<typeof machine>>

const gossip = async (from: Machine, to: Machine): Promise<void> => {
  await reconcileMcps(from.sync)
  await run(
    to.services.db.mergeSyncEntries(
      MCPS_SYNC_NAMESPACE,
      await run(from.services.db.getSyncEntries(MCPS_SYNC_NAMESPACE))
    )
  )
  await reconcileMcps(to.sync)
}

const settles = async (manager: McpManager, id: string, state: string) => {
  while (true) {
    const changed = Promise.withResolvers<void>()
    const unsubscribe = manager.subscribeServersChanged((changedId) => {
      if (changedId === id) changed.resolve()
    })
    try {
      const current = (await manager.list()).find((server) => server.id === id)
      if (current?.connectionState === state) return current
      await changed.promise
    } finally {
      unsubscribe()
    }
  }
}

const signIn = async (on: Machine, fake: FakeOAuthMcpServer): Promise<void> => {
  const created = await on.manager.create({
    authType: "oauth",
    enabled: true,
    name: "Tracker",
    transport: "http",
    url: fake.url
  })
  const { code, state } = fake.approve(await on.manager.beginOAuth(created.id))
  await on.manager.finishOAuth(state, code)
  await settles(on.manager, created.id, "connected")
}

const outcomes = (fake: FakeOAuthMcpServer) =>
  fake.refreshAttempts.map((attempt) => attempt.outcome)

describe("MCP OAuth through the shared credential vault", () => {
  it("rotates exactly once when two machines refresh the same sign-in at once", async () => {
    const env = await fleet()
    const a = await machine(env, "machine-a")
    const b = await machine(env, "machine-b")
    await signIn(a, env.fake)
    await gossip(a, b)
    await settles(b.manager, await b.trackerId(), "connected")
    const [fromA, fromB] = [await a.chat(), await b.chat()]

    env.clock.sleep(2 * HOUR)
    const release = env.fake.holdRefreshes()
    const calls = Promise.all([fromA(), fromB()])
    await env.fake.until(() => env.fake.heldRefreshes() === 1)
    await env.coordinator.until(() =>
      env.coordinator.commands.some(
        (command) => command.action === "acquire" && command.status === "busy"
      )
    )
    release()

    for (const result of await calls) expect(result).toContain(env.fake.grants()[0]?.id)
    expect(outcomes(env.fake)).toEqual(["rotated"])
    expect([...env.coordinator.records.values()].map((record) => record.generation)).toEqual([2])
    expect(env.fake.unauthorizedResponses()).toBe(0)
  })

  it("lets any machine renew while the machine that signed in is offline", async () => {
    const env = await fleet()
    const a = await machine(env, "machine-a")
    const b = await machine(env, "machine-b")
    await signIn(a, env.fake)
    await gossip(a, b)
    const fromB = await b.chat()

    env.clock.sleep(2 * HOUR)
    expect(await fromB()).toContain(env.fake.grants()[0]?.id)
    env.clock.sleep(30 * 60_000)
    expect(await (await a.chat())()).toContain(env.fake.grants()[0]?.id)

    expect(outcomes(env.fake)).toEqual(["rotated"])
    expect(env.coordinator.commands.filter((command) => command.action === "commit")).toEqual([
      { machine: "machine-b", action: "commit", status: "ready" }
    ])
  })

  it("renews before a request after sleep, and once for two chats hitting a 401", async () => {
    const env = await fleet()
    const a = await machine(env, "machine-a")
    await signIn(a, env.fake)
    const [first, second] = [await a.chat(), await a.chat()]

    env.clock.sleep(2 * HOUR)
    expect(await first()).toContain("grant-")
    expect(env.fake.unauthorizedResponses()).toBe(0)

    env.fake.invalidateAccessTokens()
    const release = env.fake.holdRefreshes()
    const calls = Promise.all([first(), second()])
    await env.fake.until(
      () => env.fake.unauthorizedResponses() >= 2 && env.fake.heldRefreshes() === 1
    )
    release()
    for (const result of await calls) expect(result).toContain("grant-")
    expect(outcomes(env.fake)).toEqual(["rotated", "rotated"])
  })

  it("asks every machine to authorize again once the grant is revoked", async () => {
    const env = await fleet()
    const a = await machine(env, "machine-a")
    const b = await machine(env, "machine-b")
    await signIn(a, env.fake)
    await gossip(a, b)
    const [fromA, fromB] = [await a.chat(), await b.chat()]

    env.fake.revokeAllGrants()
    env.clock.sleep(2 * HOUR)
    expect(await fromA()).toContain("expired or was revoked")
    expect(await fromB()).toContain("expired or was revoked")

    for (const each of [a, b]) {
      expect((await each.manager.list()).find((server) => server.name === "Tracker")).toMatchObject(
        { connectionState: "needsAuthorization", detail: expect.stringContaining("Authorize") }
      )
    }
    expect(outcomes(env.fake)).toEqual(["revoked"])
    await gossip(a, b)
    expect(await b.manager.oauthCredential(await b.trackerId())).toBeNull()

    const trackerOnB = await b.trackerId()
    const { code, state } = env.fake.approve(await b.manager.beginOAuth(trackerOnB))
    await b.manager.finishOAuth(state, code)
    await settles(b.manager, trackerOnB, "connected")
    await gossip(b, a)
    expect(await fromA()).toContain(env.fake.grants()[1]?.id)
    expect(env.fake.registeredRedirects()).toHaveLength(2)
  })

  it("does not sign other machines out when one machine cannot read the sign-in", async () => {
    const env = await fleet()
    const a = await machine(env, "machine-a")
    const elsewhere = sharedCoordinator(env.clock)
    const b = await machine(
      env,
      "machine-b",
      machineVault(elsewhere, "machine-b", env.clock, await tempDirectory())
    )
    await signIn(a, env.fake)
    await gossip(a, b)

    expect(await (await b.chat())()).toContain("can't be used on this machine")
    await gossip(b, a)
    expect(await a.manager.oauthCredential(await a.trackerId())).toMatchObject({
      id: expect.any(String)
    })
    expect(await (await a.chat())()).toContain(env.fake.grants()[0]?.id)
  })

  it("keeps the sign-in through an authorization server outage and backs off", async () => {
    const env = await fleet()
    const a = await machine(env, "machine-a")
    await signIn(a, env.fake)
    const call = await a.chat()
    env.fake.failNextRefreshes(1)
    env.clock.sleep(2 * HOUR)

    expect(await call()).toContain("Couldn't renew the Tracker sign-in")
    const trackerId = await a.trackerId()
    expect((await a.manager.list()).find((server) => server.id === trackerId)).toMatchObject({
      connectionState: "expired"
    })
    expect([...env.coordinator.records.values()][0]?.operation).toBeUndefined()
    expect(await call()).toContain("Codevisor retries automatically")
    expect(outcomes(env.fake)).toEqual(["unavailable"])

    await env.clock.scheduled(env.clock.now() + 30_000)
    const recovered = settles(a.manager, trackerId, "connected")
    env.clock.advance(30_000)
    await recovered
    expect(outcomes(env.fake)).toEqual(["unavailable", "rotated"])
    expect(await call()).toContain("grant-")
  })

  it("moves an existing sign-in into the vault without signing in again", async () => {
    const env = await fleet()
    const a = await machine(env, "machine-a")
    const b = await machine(env, "machine-b")
    const created = await a.manager.create({
      authType: "oauth",
      enabled: true,
      name: "Tracker",
      transport: "http",
      url: env.fake.url
    })
    const legacy = env.fake.mintGrant()
    await seedLegacyMcpOAuth(a.services, created.id, {
      refreshOwner: "machine-a",
      tokens: legacy.tokens,
      tokensSavedAt: env.clock.now(),
      clientInformation: { client_id: legacy.clientId }
    })

    expect(await (await a.chat())()).toContain(env.fake.grants()[0]?.id)
    expect(await a.manager.oauthCredential(created.id)).toMatchObject({ id: expect.any(String) })
    await gossip(a, b)
    env.clock.sleep(2 * HOUR)
    expect(await (await b.chat())()).toContain(env.fake.grants()[0]?.id)
    expect(outcomes(env.fake)).toEqual(["rotated"])
    expect(env.fake.grants()).toHaveLength(1)
  })

  it("coordinates refreshes on the machine itself when no cloud is configured", async () => {
    const env = await fleet()
    const dataDir = await tempDirectory()
    const a = await machine(env, "machine-a", mcpCredentialVault(dataDir, undefined, env.clock.now))
    await signIn(a, env.fake)
    const call = await a.chat()

    env.clock.sleep(2 * HOUR)
    expect(await call()).toContain(env.fake.grants()[0]?.id)

    expect(outcomes(env.fake)).toEqual(["rotated"])
    const record = (await readdir(join(dataDir, "shared-credentials"))).find(
      (file) => !file.endsWith(".receipt.json") && !file.endsWith(".lock")
    )
    const saved: unknown = JSON.parse(
      await readFile(join(dataDir, "shared-credentials", record ?? ""), "utf8")
    )
    expect(saved).toMatchObject({ record: { generation: 2, revoked: false } })
    expect(JSON.stringify(saved)).not.toContain("access-")
  })
})
