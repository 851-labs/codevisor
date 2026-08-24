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
  })

  it("responds 501 for blob and skills routes without the backing services", async () => {
    const { services } = await makeServices("server-nosync")
    const server = await startWithApp(services)
    expect((await jsonRequest(server, `/v1/sync/blobs/${"0".repeat(64)}`)).status).toBe(501)
    expect(
      (await jsonRequest(server, "/v1/sync/skills/reconcile", { method: "POST" })).status
    ).toBe(501)
  })
})
