import { describe, expect, it } from "vitest"
import { jsonRequest, makeServices, readWebSocketEvents, startWithApp } from "../test-support.js"

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
})
