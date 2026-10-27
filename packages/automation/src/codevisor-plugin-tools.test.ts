import { afterEach, describe, expect, it, vi } from "vitest"

import { call, jsonResponse, local, remote, type Recorded } from "./codevisor-agent-test-support.js"
import { maxSetupWaitMs, setupWaitMarginMs, setupWaitMs } from "./codevisor-plugin-tools.js"

afterEach(() => {
  vi.unstubAllGlobals()
})

const subscription = {
  id: "sub-1",
  sessionId: "caller",
  plugin: "server-1",
  pluginName: "Grafana",
  event: "alert.firing",
  arguments: {},
  filter: 'labels.severity == "critical"',
  explained: 'labels.severity is "critical"',
  note: "Critical prod alerts",
  once: false,
  createdBy: "agent",
  createdAt: "2026-10-27T00:00:00.000Z"
}

const eventType = {
  plugin: "server-1",
  pluginName: "Grafana",
  name: "alert.firing",
  description: "A Grafana alert started firing",
  delivery: ["push"],
  payloadSchema: { type: "object" },
  inputSchema: { type: "object" }
}

const routes: Record<string, unknown> = {
  "GET /v1/plugins/events/types": {
    types: [
      eventType,
      {
        ...eventType,
        name: "bare",
        description: undefined,
        payloadSchema: undefined,
        inputSchema: undefined
      }
    ]
  },
  "POST /v1/plugins/events/subscriptions": subscription,
  "GET /v1/plugins/events/subscriptions": {
    subscriptions: [
      {
        ...subscription,
        filter: undefined,
        note: undefined,
        pausedReason: "Paused after 200 events in a day"
      }
    ]
  },
  "DELETE /v1/plugins/events/subscriptions/sub-1": { removed: true },
  "POST /v1/plugins/events/preview": { explained: "every event", scanned: 2, matched: [] },
  "GET /v1/plugins/events/evt-1": { id: "evt-1" },
  "GET /v1/plugins/search": { items: [{ plugin: "codevisor.gmail" }] },
  "GET /v1/plugins/describe/Gmail": { plugin: "codevisor.gmail" },
  "POST /v1/plugins/setup-requests": { outcome: "connected" }
}

const fakeApi = (): Array<Recorded> => {
  const requests: Array<Recorded> = []
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: URL, init: RequestInit) => {
      const method = String(init.method)
      const path = decodeURIComponent(input.pathname)
      const body: unknown = typeof init.body === "string" ? JSON.parse(init.body) : undefined
      requests.push({ method, path, query: Object.fromEntries(input.searchParams), body })
      return jsonResponse(JSON.parse(JSON.stringify(routes[`${method} ${path}`] ?? {})))
    })
  )
  return requests
}

const requestTo = (requests: ReadonlyArray<Recorded>, method: string, path: string) =>
  requests.find((request) => request.method === method && request.path === path)

describe("events tools", () => {
  it("lists topics with the fields a filter can use", async () => {
    const requests = fakeApi()
    expect(await call(local, "events.topics", { query: "grafana" })).toEqual({
      items: [
        {
          plugin: "Grafana",
          event: "alert.firing",
          description: "A Grafana alert started firing",
          payloadSchema: { type: "object" },
          arguments: { type: "object" }
        },
        { plugin: "Grafana", event: "bare" }
      ]
    })
    expect(requestTo(requests, "GET", "/v1/plugins/events/types")?.query).toEqual({
      query: "grafana"
    })
    await call(local, "events.topics", {})
    expect(requests.at(-1)?.query).toEqual({})
  })

  it("subscribes as the calling agent and reads the filter back", async () => {
    const requests = fakeApi()
    expect(
      await call(local, "events.subscribe", {
        plugin: "Grafana",
        event: "alert.firing",
        filter: 'labels.severity == "critical"',
        arguments: { folder: "prod" },
        account: "grafana.example",
        note: "Critical prod alerts",
        once: false
      })
    ).toMatchObject({ subscriptionId: "sub-1", explained: 'labels.severity is "critical"' })
    expect(requestTo(requests, "POST", "/v1/plugins/events/subscriptions")?.body).toEqual({
      sessionId: "caller",
      plugin: "Grafana",
      event: "alert.firing",
      note: "Critical prod alerts",
      filter: 'labels.severity == "critical"',
      arguments: { folder: "prod" },
      accountId: "grafana.example",
      once: false
    })
    await call(local, "events.subscribe", { plugin: "Grafana", event: "alert.firing", note: "All" })
    expect(requests.at(-1)?.body).toEqual({
      sessionId: "caller",
      plugin: "Grafana",
      event: "alert.firing",
      note: "All"
    })
  })

  it("lists, previews, reads and removes", async () => {
    const requests = fakeApi()
    expect(await call(local, "events.subscriptions", {})).toEqual({
      items: [
        {
          subscriptionId: "sub-1",
          plugin: "Grafana",
          event: "alert.firing",
          explained: 'labels.severity is "critical"',
          once: false,
          pausedReason: "Paused after 200 events in a day"
        }
      ]
    })
    expect(requests.at(-1)?.query).toEqual({ sessionId: "caller" })
    expect(
      await call(local, "events.preview", {
        plugin: "Grafana",
        event: "alert.firing",
        filter: "true",
        account: "a"
      })
    ).toMatchObject({ scanned: 2 })
    expect(requests.at(-1)?.body).toEqual({
      plugin: "Grafana",
      event: "alert.firing",
      filter: "true",
      accountId: "a"
    })
    await call(local, "events.preview", { plugin: "Grafana", event: "alert.firing" })
    expect(requests.at(-1)?.body).toEqual({ plugin: "Grafana", event: "alert.firing" })
    expect(await call(local, "events.get", { eventId: "evt-1" })).toEqual({ id: "evt-1" })
    expect(await call(local, "events.unsubscribe", { subscriptionId: "sub-1" })).toEqual({
      subscriptionId: "sub-1",
      removed: true
    })
  })

  it("refuses to subscribe a session on another machine", async () => {
    fakeApi()
    await expect(
      call(remote, "events.subscribe", { plugin: "Grafana", event: "alert.firing", note: "x" })
    ).rejects.toThrow("machines.current")
  })
})

describe("plugin tools", () => {
  it("searches, describes and requests setup for the calling agent", async () => {
    const requests = fakeApi()
    expect(await call(local, "plugins.search", { query: "email" })).toEqual({
      items: [{ plugin: "codevisor.gmail" }]
    })
    expect(requests.at(-1)?.query).toEqual({ query: "email" })
    expect(await call(local, "plugins.describe", { plugin: "Gmail" })).toEqual({
      plugin: "codevisor.gmail"
    })
    expect(
      await call(local, "plugins.request_setup", { plugin: "Gmail", reason: "Reply to Pat" })
    ).toEqual({ outcome: "connected" })
    expect(requests.at(-1)?.body).toEqual({
      sessionId: "caller",
      plugin: "Gmail",
      reason: "Reply to Pat",
      waitMs: maxSetupWaitMs
    })
  })

  it("waits for setup only as long as the execute call allows", () => {
    const now = performance.now()
    expect(setupWaitMs(undefined)).toBe(maxSetupWaitMs)
    expect(setupWaitMs(now + setupWaitMarginMs + 1_000)).toBeLessThanOrEqual(1_000)
    expect(setupWaitMs(now)).toBe(0)
  })
})
