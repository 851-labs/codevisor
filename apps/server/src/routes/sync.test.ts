import { Effect } from "effect"
import { makeSkillsManager } from "@codevisor/skills"
import { makeBlobStore } from "@codevisor/sync"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import type { CodevisorServerServices } from "../server-context.js"
import {
  harnesses,
  jsonRequest,
  makeAgents,
  makeServices,
  readWebSocketEvents,
  run,
  startWithApp,
  tempDirs
} from "../test-support.js"

const entry = (key: string, value: unknown, wallMs: number, deviceId = "device-a") => ({
  key,
  value,
  timestamp: { wallMs, counter: 0, deviceId }
})

describe("/v1/sync", () => {
  it("merges replicas and publishes only real changes", async () => {
    const { services } = await makeServices("server-sync")
    const server = await startWithApp(services)

    // Empty replica to start.
    expect((await jsonRequest(server, "/v1/sync/settings")).body).toEqual({
      namespace: "settings",
      entries: []
    })

    // First push lands and returns the merged document.
    const first = await jsonRequest(server, "/v1/sync/settings", {
      body: JSON.stringify({ entries: [entry("channel", "alpha", 10)] }),
      method: "PUT"
    })
    expect(first.status).toBe(200)
    expect(first.body).toMatchObject({
      namespace: "settings",
      entries: [entry("channel", "alpha", 10)]
    })

    // An older concurrent write does NOT replace it — the PUT response is
    // the pull that corrects the writer.
    const stale = await jsonRequest(server, "/v1/sync/settings", {
      body: JSON.stringify({ entries: [entry("channel", "stable", 5, "device-b")] }),
      method: "PUT"
    })
    expect(stale.body).toMatchObject({ entries: [entry("channel", "alpha", 10)] })

    // Exactly ONE sync.changed published: the stale push emitted nothing.
    const events = (await readWebSocketEvents(server, 1, 0)) as Array<{
      readonly kind: string
      readonly payload: { readonly namespace?: string }
    }>
    expect(events[0]?.kind).toBe("sync.changed")
    expect(events[0]?.payload).toMatchObject({ namespace: "settings" })

    // Invalid namespaces are refused, and only GET and PUT exist.
    expect((await jsonRequest(server, "/v1/sync/Bad%2FName")).status).toBe(400)
    expect((await jsonRequest(server, "/v1/sync/settings", { method: "POST" })).status).toBe(405)
  })

  it("serves and verifies skill blobs, and reconciles over HTTP", async () => {
    const { services } = await makeServices("server-skills")
    const home = mkdtempSync(join(tmpdir(), "skills-home-"))
    const blobDir = mkdtempSync(join(tmpdir(), "sync-blobs-"))
    tempDirs.push(home, blobDir)
    const skills = makeSkillsManager({ agents: makeAgents(), homedir: home, env: {} })
    await skills.create({ name: "Deploy", description: "ship it" })
    const server = await startWithApp({
      ...services,
      skills,
      syncBlobs: makeBlobStore(blobDir)
    })

    const reconcile = await jsonRequest(server, "/v1/sync/skills/reconcile", { method: "POST" })
    expect(reconcile.status).toBe(200)
    expect(reconcile.body).toMatchObject({ published: ["deploy"], missingBlobs: [] })

    // Idempotent: a second pass changes (and publishes) nothing.
    const again = await jsonRequest(server, "/v1/sync/skills/reconcile", { method: "POST" })
    expect(again.body).toMatchObject({ published: [], applied: [], removed: [] })

    const document = await jsonRequest(server, "/v1/sync/skills")
    const hash = (document.body as { entries: Array<{ value: { hash: string } }> }).entries[0]
      ?.value.hash as string

    // GET serves the archive; bad ids, unknown blobs, and other methods
    // are refused.
    const blob = await fetch(`${server.url}/v1/sync/blobs/${hash}`)
    expect(blob.status).toBe(200)
    const bytes = Buffer.from(await blob.arrayBuffer())
    expect(bytes.byteLength).toBeGreaterThan(0)
    expect((await jsonRequest(server, "/v1/sync/blobs/not-hex")).status).toBe(400)
    expect((await jsonRequest(server, `/v1/sync/blobs/${"0".repeat(64)}`)).status).toBe(404)
    expect((await jsonRequest(server, `/v1/sync/blobs/${hash}`, { method: "POST" })).status).toBe(
      405
    )

    // PUT verifies the contents against the claimed id.
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

    // MCP reconcile and the roster publish ride the same surface: a real
    // definition publishes (and emits sync.changed), and a repeat roster
    // publish with nothing new stays silent.
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
    // Idempotent: a second pass changes (and publishes) nothing.
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

  it("gates every sync surface behind the participation flag", async () => {
    const { services } = await makeServices("server-optout")
    const server = await startWithApp(services)

    // Participating by default.
    expect((await jsonRequest(server, "/v1/sync-participation")).body).toEqual({ enabled: true })

    // Off: every /v1/sync/* surface refuses, while the flag itself stays
    // reachable (that is how it gets turned back on) and remembers.
    const off = await jsonRequest(server, "/v1/sync-participation", {
      body: JSON.stringify({ enabled: false }),
      method: "PUT"
    })
    expect(off.status).toBe(200)
    expect(off.body).toEqual({ enabled: false })
    expect((await jsonRequest(server, "/v1/sync-participation")).body).toEqual({ enabled: false })
    expect((await jsonRequest(server, "/v1/sync/settings")).status).toBe(403)
    const put = await jsonRequest(server, "/v1/sync/settings", {
      body: JSON.stringify({ entries: [] }),
      method: "PUT"
    })
    expect(put.status).toBe(403)
    expect((await jsonRequest(server, `/v1/sync/blobs/${"0".repeat(64)}`)).status).toBe(403)
    expect(
      (await jsonRequest(server, "/v1/sync/skills/reconcile", { method: "POST" })).status
    ).toBe(403)
    expect((await jsonRequest(server, "/v1/sync/mcps/reconcile", { method: "POST" })).status).toBe(
      403
    )
    expect(
      (await jsonRequest(server, "/v1/sync/accounts/publish", { method: "POST" })).status
    ).toBe(403)
    expect(
      (await jsonRequest(server, "/v1/sync/mcp-readiness/publish", { method: "POST" })).status
    ).toBe(403)

    // Only GET and PUT exist on the flag.
    expect((await jsonRequest(server, "/v1/sync-participation", { method: "POST" })).status).toBe(
      405
    )

    // Back on: the plane opens up again.
    const on = await jsonRequest(server, "/v1/sync-participation", {
      body: JSON.stringify({ enabled: true }),
      method: "PUT"
    })
    expect(on.body).toEqual({ enabled: true })
    expect((await jsonRequest(server, "/v1/sync/settings")).status).toBe(200)
  })

  it("reconciles harnesses over HTTP with auth and lifecycle gates", async () => {
    const { services } = await makeServices("server-hsync")
    // A custom-spec store rides along: the local spec publishes and the
    // seeded fleet spec applies through one replace.
    const replaced: Array<ReadonlyArray<unknown>> = []
    const customHarnesses = {
      list: () => Promise.resolve([{ id: "mybot", name: "My Bot", command: "mybot" }]),
      replace: (specs: ReadonlyArray<unknown>) => {
        replaced.push(specs)
        return Promise.resolve()
      },
      test: () => Promise.resolve({ ok: true })
    } as unknown as NonNullable<CodevisorServerServices["customHarnesses"]>
    await run(
      services.db.mergeSyncEntries("harnesses", [
        {
          key: "custom:fleetbot",
          value: { id: "fleetbot", name: "Fleet Bot", command: "fleetbot" },
          timestamp: { wallMs: 10, counter: 0, deviceId: "z" }
        }
      ])
    )
    const server = await startWithApp({ ...services, customHarnesses })

    // Publish: the fake catalog's codex (ready, enabled) enters the plane.
    const first = await jsonRequest(server, "/v1/sync/harnesses/reconcile", { method: "POST" })
    expect(first.status).toBe(200)
    expect(first.body).toMatchObject({
      published: ["codex", "custom:mybot"],
      applied: ["custom:fleetbot"],
      blocked: []
    })
    expect(replaced.at(-1)?.length).toBe(2)
    const doc = await jsonRequest(server, "/v1/sync/harnesses")
    expect(
      (doc.body as { entries: Array<{ key: string; value: unknown }> }).entries[0]?.value
    ).toEqual({ enabled: true, installed: true })

    // A machine whose codex is NOT installed, told to install it, with no
    // lifecycle manager: blocked, never failed.
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

    // With a lifecycle manager present, the same want starts a real install.
    const { services: installable } = await makeServices("server-hsync-install")
    await run(
      installable.db.mergeSyncEntries("harnesses", [
        {
          key: "codex",
          value: { enabled: true, installed: true },
          timestamp: { wallMs: 10, counter: 0, deviceId: "z" }
        },
        // A custom spec arriving on a machine with no custom store: the
        // apply is a quiet no-op rather than a failure.
        {
          key: "custom:orphan",
          value: { id: "orphan", name: "Orphan", command: "orphan" },
          timestamp: { wallMs: 10, counter: 0, deviceId: "z" }
        }
      ])
    )
    const installs: Array<string> = []
    const lifecycle = {
      subscribe: () => () => {},
      onGateReleased: () => () => {},
      beginInstall: (harnessId: string) => {
        installs.push(harnessId)
        return Promise.resolve({ terminalId: "t1" })
      }
    } as unknown as NonNullable<CodevisorServerServices["lifecycle"]>
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

    // Auth gating end to end: loggedOut blocks the enable; authenticated
    // and notRequired both let it through.
    const reconcileWithAuth = async (state: string, serverId: string) => {
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
      const auth = {
        subscribe: () => () => {},
        decorateHarnesses: (list: ReadonlyArray<unknown>) =>
          Promise.resolve(
            (list as Array<Record<string, unknown>>).map((harness) => ({
              ...harness,
              auth: { state }
            }))
          )
      } as unknown as NonNullable<CodevisorServerServices["auth"]>
      const authedServer = await startWithApp({ ...base, auth })
      return jsonRequest(authedServer, "/v1/sync/harnesses/reconcile", { method: "POST" })
    }
    expect((await reconcileWithAuth("loggedOut", "server-h1")).body).toMatchObject({
      blocked: [{ id: "codex", reason: "Sign in before this harness can be enabled" }]
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
        // First contact for the locally-present plugin: the fleet's enabled
        // state wins and applies through the manager.
        {
          key: "acme.paused",
          value: { enabled: true, source: "acme/paused" },
          timestamp: { wallMs: 11, counter: 0, deviceId: "z" }
        }
      ])
    )
    // One managed plugin with a registry receipt, one receiptless managed
    // install, one linked dev plugin — only the first syncs.
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
    let pluginList = [
      { id: "acme.paused", enabled: false, source: "managed", path: receiptDir },
      { id: "acme.bare", enabled: true, source: "managed", path: bareDir },
      { id: "dev.x", enabled: true, source: "linked", path: "/dev/x" }
    ]
    const plugins = {
      subscribe: () => () => {},
      close: () => {},
      list: () => Promise.resolve({ plugins: [...pluginList] }),
      importRemote: (request: { source: string }) => {
        installs.push(request.source)
        return Promise.resolve({ id: "acme.tunes" })
      },
      setEnabled: (pluginId: string, enabled: boolean) => {
        enables.push([pluginId, enabled])
        pluginList = pluginList.map((plugin) =>
          plugin.id === pluginId ? { ...plugin, enabled } : plugin
        )
        return Promise.resolve({})
      },
      remove: (pluginId: string) => {
        removals.push(pluginId)
        pluginList = pluginList.filter((plugin) => plugin.id !== pluginId)
        return Promise.resolve({ plugins: [] })
      }
    } as unknown as NonNullable<CodevisorServerServices["plugins"]>
    const server = await startWithApp({ ...services, plugins })

    const result = await jsonRequest(server, "/v1/sync/plugins/reconcile", { method: "POST" })
    expect(result.status).toBe(200)
    expect(result.body).toMatchObject({
      published: [],
      installed: ["acme.tunes"]
    })
    expect([...(result.body as { applied: Array<string> }).applied].sort()).toEqual([
      "acme.paused",
      "acme.tunes"
    ])
    expect(installs).toEqual(["acme/tunes"])
    expect(enables).toEqual([["acme.paused", true]])

    // A fleet tombstone uninstalls through the manager on the next pass.
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

    // Without a plugin manager the surface answers 501.
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
