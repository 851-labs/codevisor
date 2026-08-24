import { makeSkillsManager } from "@codevisor/skills"
import { makeBlobStore } from "@codevisor/sync"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import {
  jsonRequest,
  makeAgents,
  makeServices,
  readWebSocketEvents,
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
