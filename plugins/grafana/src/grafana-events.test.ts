import { heartbeatIntervalMs } from "@codevisor/plugin-kit"
import {
  anyResult,
  type ConnectedClient,
  connectClient,
  manualClock,
  openStream,
  withAccount
} from "@codevisor/plugin-kit/test-support"
import { afterEach, describe, expect, it, vi } from "vitest"

import { createGrafanaServer } from "./grafana-server.js"

const connections: Array<ConnectedClient> = []

const fields = {
  url: "https://grafana.example.com",
  token: "glsa_token",
  webhookSecret: "hook-secret"
}
const account = withAccount("acct-1", fields)
const otherAccount = withAccount("acct-2", { ...fields, webhookSecret: "other-secret" })

const connect = async () => {
  const clock = manualClock()
  const connected = await connectClient(createGrafanaServer({ fetch: vi.fn(), clock }))
  connections.push(connected)
  return { ...connected, clock }
}

const firing = {
  status: "firing",
  labels: { alertname: "HighCPU", severity: "critical", host: "db-1" },
  annotations: { summary: "CPU above 90%" },
  fingerprint: "fp-1",
  startsAt: "2026-10-27T11:59:00Z",
  endsAt: "0001-01-01T00:00:00Z",
  generatorURL: "https://grafana.example.com/alerting/grafana/rule-1/view",
  values: { B: 93.5, C: 1 }
}

const resolved = {
  status: "resolved",
  labels: { severity: "warning" },
  fingerprint: "fp-2",
  startsAt: "2026-10-27T11:00:00Z",
  endsAt: "2026-10-27T11:58:00Z",
  values: null
}

const grafanaBody = (alerts: Array<Record<string, unknown>>) =>
  Buffer.from(
    JSON.stringify({ receiver: "codevisor", status: "firing", groupKey: "{}:{}", alerts })
  ).toString("base64")

const webhook = (
  connected: ConnectedClient,
  options: {
    headers?: Record<string, string>
    body?: string
    ingress?: string
    meta?: Record<string, unknown>
  }
) =>
  connected.client.request(
    {
      method: "codevisor/webhook",
      params: {
        _meta: options.meta ?? account,
        ingress: options.ingress ?? "alerts",
        request: {
          method: "POST",
          headers: options.headers ?? { authorization: "Bearer hook-secret" },
          body: options.body ?? grafanaBody([firing, resolved]),
          receivedAt: "2026-10-27T12:00:00Z"
        }
      }
    },
    anyResult
  )

describe("grafana events", () => {
  afterEach(async () => {
    await Promise.all(connections.splice(0).map((connected) => connected.client.close()))
  })

  it("lists push-only alert events whose labels and annotations are string maps", async () => {
    const { client } = await connect()

    const listed = await client.request({ method: "events/list" }, anyResult)

    const stringMap = { type: "object", additionalProperties: { type: "string" } }
    const alertSchema = {
      payloadSchema: { properties: { labels: stringMap, annotations: stringMap } }
    }

    expect(listed.events).toMatchObject([
      { name: "alert.firing", delivery: ["push"], ...alertSchema },
      { name: "alert.resolved", delivery: ["push"], ...alertSchema }
    ])
  })

  it("splits a verified webhook into one event per alert on the account's streams", async () => {
    const connected = await connect()
    const firingStream = await openStream(connected, {
      name: "alert.firing",
      cursor: null,
      _meta: account
    })
    const resolvedStream = await openStream(connected, {
      name: "alert.resolved",
      cursor: null,
      _meta: account
    })

    const outcome = await webhook(connected, { headers: { Authorization: "Bearer hook-secret" } })
    const fired = await connected.inbox.next(
      "notifications/events/event",
      firingStream.subscriptionId
    )
    const cleared = await connected.inbox.next(
      "notifications/events/event",
      resolvedStream.subscriptionId
    )

    expect(outcome).toEqual({ accepted: 2, status: 200 })
    expect(firingStream.active.params).toMatchObject({ cursor: null, truncated: false })
    expect(fired.params).toMatchObject({
      eventId: "fp-1:2026-10-27T11:59:00Z",
      name: "alert.firing",
      timestamp: "2026-10-27T11:59:00Z",
      cursor: null,
      data: {
        fingerprint: "fp-1",
        status: "firing",
        alertname: "HighCPU",
        labels: firing.labels,
        annotations: firing.annotations,
        startsAt: firing.startsAt,
        endsAt: firing.endsAt,
        generatorURL: firing.generatorURL,
        values: firing.values
      }
    })
    expect(cleared.params).toMatchObject({
      eventId: "fp-2:2026-10-27T11:00:00Z",
      timestamp: "2026-10-27T11:58:00Z",
      data: { alertname: "", annotations: {}, generatorURL: "", values: {} }
    })
  })

  it("does not deliver another account's alerts", async () => {
    const connected = await connect()
    const mine = await openStream(connected, { name: "alert.firing", cursor: null, _meta: account })
    const theirs = await openStream(connected, {
      name: "alert.firing",
      cursor: null,
      _meta: otherAccount
    })

    await webhook(connected, {})
    await connected.inbox.next("notifications/events/event", mine.subscriptionId)

    expect(
      connected.inbox.forSubscription(theirs.subscriptionId).map((message) => message.method)
    ).toEqual(["notifications/events/active"])
  })

  it("rejects webhooks without the account's bearer secret", async () => {
    const connected = await connect()
    const stream = await openStream(connected, {
      name: "alert.firing",
      cursor: null,
      _meta: account
    })

    const wrong = await webhook(connected, { headers: { authorization: "Bearer guess" } })
    const missing = await webhook(connected, { headers: {} })
    const foreign = await webhook(connected, { meta: otherAccount })
    const noSecret = await webhook(connected, {
      meta: withAccount("acct-1", { url: fields.url, token: fields.token })
    })
    const noAccount = await webhook(connected, { meta: {} })

    expect([wrong, missing, foreign, noSecret, noAccount]).toEqual(
      Array.from({ length: 5 }, () => ({ accepted: 0, status: 401 }))
    )
    expect(connected.inbox.forSubscription(stream.subscriptionId)).toHaveLength(1)
  })

  it("rejects unknown ingresses and malformed bodies", async () => {
    const connected = await connect()

    const unknownIngress = await webhook(connected, { ingress: "deploys" })
    const notJson = await webhook(connected, { body: Buffer.from("<html>").toString("base64") })
    const notGrafana = await webhook(connected, {
      body: Buffer.from('{"alerts":"none"}').toString("base64")
    })

    expect(unknownIngress).toEqual({ accepted: 0, status: 404 })
    expect([notJson, notGrafana]).toEqual([
      { accepted: 0, status: 400 },
      { accepted: 0, status: 400 }
    ])
  })

  it("skips alerts in states other than firing and resolved", async () => {
    const connected = await connect()

    const outcome = await webhook(connected, {
      body: grafanaBody([{ ...firing, status: "pending" }])
    })

    expect(outcome).toEqual({ accepted: 0, status: 200 })
  })

  it("requires an account to open a stream and refuses poll delivery", async () => {
    const connected = await connect()

    await expect(
      connected.client.request(
        { method: "events/stream", params: { name: "alert.firing" } },
        anyResult
      )
    ).rejects.toMatchObject({
      code: -32024,
      data: { reason: "A Grafana account with a url and token is required." }
    })
    await expect(
      connected.client.request(
        { method: "events/poll", params: { name: "alert.firing", cursor: null } },
        anyResult
      )
    ).rejects.toMatchObject({ code: -32026, data: { feature: "deliveryMode", value: "poll" } })
    await expect(
      connected.client.request(
        { method: "events/poll", params: { name: "alert.updated" } },
        anyResult
      )
    ).rejects.toMatchObject({ code: -32023 })
  })

  it("sends null-cursor heartbeats and stops a cancelled stream", async () => {
    const connected = await connect()
    const cancel = new AbortController()
    const stream = await openStream(
      connected,
      { name: "alert.firing", cursor: null, _meta: account },
      cancel.signal
    )

    connected.clock.advance(heartbeatIntervalMs)
    const heartbeat = await connected.inbox.next(
      "notifications/events/heartbeat",
      stream.subscriptionId
    )
    cancel.abort()
    await expect(stream.closed).rejects.toThrow()
    const outcome = await webhook(connected, {})

    expect(heartbeat.params).toMatchObject({ cursor: null })
    expect(outcome.accepted).toBe(2)
    expect(connected.inbox.forSubscription(stream.subscriptionId)).toHaveLength(2)
    expect(connected.clock.timers()).toBe(0)
  })
})
