import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode, type HarnessAuthState, type PluginSummary } from "@codevisor/api"
import { makeSkillStore } from "@codevisor/skills"
import { makeBlobStore } from "@codevisor/sync"
import { Effect, Schema } from "effect"
import { describe, expect, it } from "vitest"

import {
  harnesses,
  jsonRequest,
  makeServices,
  pluginSummary,
  readWebSocketEvents,
  run,
  startWithApp,
  tempDirs
} from "../test-support.js"
import {
  authStatus,
  fakeHarnessAuth,
  fakeHarnessLifecycle,
  fakePlugins,
  syncRows
} from "./harness-auth-test-support.js"
import { field, itemsOf } from "./response-test-support.js"

const entry = (key: string, value: unknown, wallMs: number, deviceId = "device-a") => ({
  key,
  value,
  timestamp: { wallMs, counter: 0, deviceId }
})

const reconcileWithAuth = async (state: HarnessAuthState, serverId: string) => {
  const { services: base } = await makeServices(serverId)
  await run(base.db.setHarnessEnabled("codex", false))
  await run(
    base.db.mergeSyncEntries("harnesses", [
      {
        key: "codex",
        value: { enabled: true, installed: true },
        timestamp: { wallMs: 10, counter: 0, deviceId: "z" }
      }
    ])
  )
  const auth = fakeHarnessAuth({
    subscribe: () => () => {},
    decorateHarnesses: (list) =>
      Promise.resolve(list.map((harness) => ({ ...harness, auth: authStatus(state) })))
  })
  const authedServer = await startWithApp({ ...base, auth })
  return jsonRequest(authedServer, "/v1/sync/harnesses/reconcile", { method: "POST" })
}

describe("/v1/sync", () => {
  it("merges replicas and publishes only real changes", async () => {
    const { services } = await makeServices("server-sync")
    const server = await startWithApp(services)

    expect((await jsonRequest(server, "/v1/sync/settings")).body).toEqual({
      namespace: "settings",
      entries: []
    })

    const first = await jsonRequest(server, "/v1/sync/settings", {
      body: JSON.stringify({ entries: [entry("channel", "alpha", 10)] }),
      method: "PUT"
    })
    expect(first.status).toBe(200)
    expect(first.body).toMatchObject({
      namespace: "settings",
      entries: [entry("channel", "alpha", 10)]
    })

    const stale = await jsonRequest(server, "/v1/sync/settings", {
      body: JSON.stringify({ entries: [entry("channel", "stable", 5, "device-b")] }),
      method: "PUT"
    })
    expect(stale.body).toMatchObject({ entries: [entry("channel", "alpha", 10)] })

    const events = await readWebSocketEvents(server, 1, 0)
    expect(field(events[0], "kind")).toBe("sync.changed")
    expect(field(events[0], "payload")).toMatchObject({ namespace: "settings" })

    expect((await jsonRequest(server, "/v1/sync/Bad%2FName")).status).toBe(400)
    expect((await jsonRequest(server, "/v1/sync/settings", { method: "POST" })).status).toBe(405)
  })

  it("serves and verifies skill blobs, and reconciles over HTTP", async () => {
    const { services } = await makeServices("server-skills")
    const home = mkdtempSync(join(tmpdir(), "skills-home-"))
    const blobDir = mkdtempSync(join(tmpdir(), "sync-blobs-"))
    tempDirs.push(home, blobDir)
    const skills = makeSkillStore({ dir: join(home, "skills") })
    await skills.create({ name: "Deploy", description: "ship it" })
    const server = await startWithApp({
      ...services,
      skills,
      syncBlobs: makeBlobStore(blobDir)
    })

    const reconcile = await jsonRequest(server, "/v1/sync/skills/reconcile", { method: "POST" })
    expect(reconcile.status).toBe(200)
    expect(reconcile.body).toMatchObject({ published: ["deploy"], missingBlobs: [] })

    const again = await jsonRequest(server, "/v1/sync/skills/reconcile", { method: "POST" })
    expect(again.body).toMatchObject({ published: [], applied: [], removed: [] })

    const document = await jsonRequest(server, "/v1/sync/codevisor-skills")
    const hash = decode(Schema.String)(
      field(field(itemsOf(field(document.body, "entries"))[0], "value"), "hash")
    )

    const blob = await fetch(`${server.url}/v1/sync/blobs/${hash}`)
    expect(blob.status).toBe(200)
    const bytes = Buffer.from(await blob.arrayBuffer())
    expect(bytes.byteLength).toBeGreaterThan(0)
    expect((await jsonRequest(server, "/v1/sync/blobs/not-hex")).status).toBe(400)
    expect((await jsonRequest(server, `/v1/sync/blobs/${"0".repeat(64)}`)).status).toBe(404)
    expect((await jsonRequest(server, `/v1/sync/blobs/${hash}`, { method: "POST" })).status).toBe(
      405
    )

    const stored = await fetch(`${server.url}/v1/sync/blobs/${hash}`, {
      body: new Uint8Array(bytes),
      method: "PUT"
    })
    expect(stored.status).toBe(200)
    const mismatched = await fetch(`${server.url}/v1/sync/blobs/${"1".repeat(64)}`, {
      body: new Uint8Array(bytes),
      method: "PUT"
    })
    expect(mismatched.status).toBe(400)

    await services.mcp?.create({
      authType: "none",
      enabled: false,
      name: "Synced",
      transport: "http",
      url: "https://synced.example.com/mcp"
    })
    const mcpReconcile = await jsonRequest(server, "/v1/sync/mcps/reconcile", { method: "POST" })
    expect(mcpReconcile.status).toBe(200)
    expect(mcpReconcile.body).toMatchObject({ published: ["Synced"] })
    expect(
      (await jsonRequest(server, "/v1/sync/mcps/reconcile", { method: "POST" })).body
    ).toMatchObject({ published: [] })
    expect(
      (await jsonRequest(server, "/v1/sync/accounts/publish", { method: "POST" })).status
    ).toBe(200)
    expect(
      (await jsonRequest(server, "/v1/sync/accounts/publish", { method: "POST" })).body
    ).toEqual({ published: false })
  })

  it("serves every sync surface regardless of a legacy participation flag", async () => {
    const { services } = await makeServices("server-optout")
    await run(services.db.mergeSyncEntries("local.sync", [entry("enabled", false, 1)]))
    const server = await startWithApp(services)

    expect((await jsonRequest(server, "/v1/sync/settings")).status).toBe(200)
    expect((await jsonRequest(server, "/v1/sync/mcps/reconcile", { method: "POST" })).status).toBe(
      200
    )
    expect((await jsonRequest(server, "/v1/sync-participation")).status).toBe(404)
  })

  it("reconciles harnesses over HTTP with auth and lifecycle gates", async () => {
    const { services } = await makeServices("server-hsync")
    const server = await startWithApp(services)

    const first = await jsonRequest(server, "/v1/sync/harnesses/reconcile", { method: "POST" })
    expect(first.status).toBe(200)
    expect(first.body).toMatchObject({
      published: ["codex"],
      applied: [],
      blocked: []
    })
    const doc = await jsonRequest(server, "/v1/sync/harnesses")
    const entries = itemsOf(field(doc.body, "entries"))
    const codex = entries.find((synced) => field(synced, "key") === "codex")
    expect(field(codex, "value")).toMatchObject({
      enabled: true,
      installed: true,
      uninstall: false
    })

    const { services: bare } = await makeServices("server-hsync-bare")
    await run(
      bare.db.mergeSyncEntries("harnesses", [
        {
          key: "codex",
          value: { enabled: true, installed: true },
          timestamp: { wallMs: 10, counter: 0, deviceId: "z" }
        }
      ])
    )
    const blockedServer = await startWithApp({
      ...bare,
      agents: {
        ...bare.agents,
        discoverHarnesses: Effect.succeed(
          harnesses.map((harness) => ({
            ...harness,
            readiness: { state: "unavailable" as const }
          }))
        )
      }
    })
    const blocked = await jsonRequest(blockedServer, "/v1/sync/harnesses/reconcile", {
      method: "POST"
    })
    expect(blocked.body).toMatchObject({
      blocked: [{ id: "codex", reason: "Harness install unavailable on this machine" }]
    })
    const readiness = (await jsonRequest(blockedServer, "/v1/sync/harness-readiness")).body
    expect(syncRows(readiness, "harnesses")).toContainEqual(
      expect.objectContaining({
        id: "codex",
        state: "blocked",
        reason: "Harness install unavailable on this machine"
      })
    )

    const { services: installable } = await makeServices("server-hsync-install")
    await run(
      installable.db.mergeSyncEntries("harnesses", [
        {
          key: "codex",
          value: { enabled: true, installed: true },
          timestamp: { wallMs: 10, counter: 0, deviceId: "z" }
        }
      ])
    )
    const installs: Array<string> = []
    const lifecycle = fakeHarnessLifecycle({
      subscribe: () => () => {},
      onGateReleased: () => () => {},
      decorateHarnesses: async (items) => items,
      beginInstall: (harnessId) => {
        installs.push(harnessId)
        return Promise.resolve({ terminalId: "t1" })
      }
    })
    const installServer = await startWithApp({
      ...installable,
      lifecycle,
      agents: {
        ...installable.agents,
        discoverHarnesses: Effect.succeed(
          harnesses.map((harness) => ({
            ...harness,
            readiness: { state: "unavailable" as const }
          }))
        )
      }
    })
    const installing = await jsonRequest(installServer, "/v1/sync/harnesses/reconcile", {
      method: "POST"
    })
    expect(installing.body).toMatchObject({ installing: ["codex"] })
    expect(installs).toEqual(["codex"])

    expect((await reconcileWithAuth("unauthenticated", "server-h1")).body).toMatchObject({
      blocked: [{ id: "codex", reason: "Sign in required" }]
    })
    expect((await reconcileWithAuth("authenticated", "server-h2")).body).toMatchObject({
      applied: ["codex"]
    })
    expect((await reconcileWithAuth("notRequired", "server-h3")).body).toMatchObject({
      applied: ["codex"]
    })
  })

  it("reconciles plugins over HTTP from install receipts", async () => {
    const { services } = await makeServices("server-psync")
    await run(
      services.db.mergeSyncEntries("plugins", [
        {
          key: "acme.tunes",
          value: { enabled: true, source: "acme/tunes" },
          timestamp: { wallMs: 10, counter: 0, deviceId: "z" }
        },
        {
          key: "acme.paused",
          value: { enabled: true, source: "acme/paused" },
          timestamp: { wallMs: 11, counter: 0, deviceId: "z" }
        }
      ])
    )
    const receiptDir = mkdtempSync(join(tmpdir(), "plugin-receipt-"))
    const bareDir = mkdtempSync(join(tmpdir(), "plugin-bare-"))
    tempDirs.push(receiptDir, bareDir)
    writeFileSync(
      join(receiptDir, ".codevisor-install.json"),
      JSON.stringify({
        schemaVersion: 1,
        pluginId: "acme.paused",
        source: {
          kind: "github",
          url: "https://github.com/acme/paused",
          repo: "acme/paused",
          tracking: "registry"
        },
        resolvedCommit: "a".repeat(40),
        installedVersion: "1.0.0",
        installedAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z"
      })
    )
    const installs: Array<string> = []
    const enables: Array<readonly [string, boolean]> = []
    const removals: Array<string> = []
    let pluginList: Array<PluginSummary> = [
      { ...pluginSummary, id: "acme.paused", enabled: false, source: "managed", path: receiptDir },
      { ...pluginSummary, id: "acme.bare", enabled: true, source: "managed", path: bareDir },
      { ...pluginSummary, id: "dev.x", enabled: true, source: "linked", path: "/dev/x" }
    ]
    const plugins = fakePlugins({
      subscribe: () => () => {},
      close: () => {},
      list: () => Promise.resolve({ plugins: [...pluginList] }),
      importRemote: (request) => {
        installs.push(request.source)
        return Promise.resolve({ ...pluginSummary, id: "acme.tunes" })
      },
      setEnabled: (pluginId, enabled) => {
        enables.push([pluginId, enabled])
        pluginList = pluginList.map((plugin) =>
          plugin.id === pluginId ? { ...plugin, enabled } : plugin
        )
        return Promise.resolve({ ...pluginSummary, id: pluginId, enabled })
      },
      remove: (pluginId) => {
        removals.push(pluginId)
        pluginList = pluginList.filter((plugin) => plugin.id !== pluginId)
        return Promise.resolve({ plugins: [] })
      }
    })
    const server = await startWithApp({ ...services, plugins })

    const result = await jsonRequest(server, "/v1/sync/plugins/reconcile", { method: "POST" })
    expect(result.status).toBe(200)
    expect(result.body).toMatchObject({
      published: [],
      installed: ["acme.tunes"]
    })
    expect(
      decode(Schema.Struct({ applied: Schema.Array(Schema.String) }))(
        result.body
      ).applied.toSorted()
    ).toEqual(["acme.paused", "acme.tunes"])
    expect(installs).toEqual(["acme/tunes"])
    expect(enables).toEqual([["acme.paused", true]])

    await run(
      services.db.mergeSyncEntries("plugins", [
        {
          key: "acme.paused",
          value: null,
          deleted: true,
          timestamp: { wallMs: 20_000_000_000_000, counter: 0, deviceId: "z" }
        }
      ])
    )
    await jsonRequest(server, "/v1/sync/plugins/reconcile", { method: "POST" })
    expect(removals).toEqual(["acme.paused"])

    const { services: bare } = await makeServices("server-psync-bare")
    const bareServer = await startWithApp(bare)
    expect(
      (await jsonRequest(bareServer, "/v1/sync/plugins/reconcile", { method: "POST" })).status
    ).toBe(501)
  })

  it("responds 501 for sync routes without the backing services", async () => {
    const { services } = await makeServices("server-nosync")
    const { mcp, ...withoutMcp } = services
    void mcp
    const server = await startWithApp(withoutMcp)
    expect((await jsonRequest(server, `/v1/sync/blobs/${"0".repeat(64)}`)).status).toBe(501)
    expect(
      (await jsonRequest(server, "/v1/sync/skills/reconcile", { method: "POST" })).status
    ).toBe(501)
    expect((await jsonRequest(server, "/v1/sync/mcps/reconcile", { method: "POST" })).status).toBe(
      501
    )
  })
})
