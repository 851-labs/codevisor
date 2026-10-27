import {
  type ConnectedClient,
  connectClient,
  manualClock,
  toolText,
  withAccount
} from "@codevisor/plugin-kit/test-support"
import { afterEach, describe, expect, it, vi } from "vitest"
import { z } from "zod"

import type { Fetch } from "./grafana-api.js"
import { createGrafanaServer } from "./grafana-server.js"

const connections: Array<ConnectedClient> = []

const fields = {
  url: "https://grafana.example.com/",
  token: "glsa_token",
  webhookSecret: "hook-secret"
}

const connect = async (fetcher: Fetch) => {
  const connected = await connectClient(
    createGrafanaServer({ fetch: fetcher, clock: manualClock() })
  )
  connections.push(connected)
  return connected
}

const respond = (status: number, body: string) =>
  vi.fn<Fetch>(async () => new Response(body, { status }))

const call = (
  connected: ConnectedClient,
  name: string,
  args?: Record<string, unknown>,
  meta = withAccount("acct-1", fields)
) =>
  connected.client.callTool({
    name,
    ...(args === undefined ? {} : { arguments: args }),
    _meta: meta
  })

describe("grafana tools", () => {
  afterEach(async () => {
    await Promise.all(connections.splice(0).map((connected) => connected.client.close()))
  })

  it("lists its tools and declares the events and webhooks extensions", async () => {
    const connected = await connect(respond(200, "{}"))

    const { tools } = await connected.client.listTools()

    expect(tools.map((tool) => tool.name)).toEqual(["list_alerts", "get_alert_rule", "query"])
    expect(connected.client.getServerCapabilities()?.extensions).toEqual({
      "io.modelcontextprotocol/events": { listChanged: false },
      "dev.codevisor/webhooks": { ingress: [{ name: "alerts", title: "Grafana alert webhook" }] }
    })
  })

  it("lists alerts with the account's url and service account token", async () => {
    const body = {
      status: "success",
      data: { alerts: [{ labels: { alertname: "HighCPU" }, state: "Alerting" }] }
    }
    const fetcher = respond(200, JSON.stringify(body))
    const connected = await connect(fetcher)

    const result = await call(connected, "list_alerts")

    expect(JSON.parse(toolText(result))).toEqual(body)
    expect(fetcher).toHaveBeenCalledWith(
      "https://grafana.example.com/api/prometheus/grafana/api/v1/alerts",
      {
        method: "GET",
        headers: {
          Authorization: "Bearer glsa_token",
          Accept: "application/json",
          "Content-Type": "application/json"
        }
      }
    )
  })

  it("gets an alert rule by its url-encoded uid", async () => {
    const fetcher = respond(200, '{"uid":"a/b"}')
    const connected = await connect(fetcher)

    await call(connected, "get_alert_rule", { uid: "a/b" })

    expect(fetcher.mock.calls[0]?.[0]).toBe(
      "https://grafana.example.com/api/v1/provisioning/alert-rules/a%2Fb"
    )
  })

  it("posts a datasource query with a default time range", async () => {
    const fetcher = respond(200, '{"results":{}}')
    const connected = await connect(fetcher)

    await call(connected, "query", { datasourceUid: "prom", query: { expr: "up", refId: "Q" } })

    expect(fetcher.mock.calls[0]?.[0]).toBe("https://grafana.example.com/api/ds/query")
    expect(fetcher.mock.calls[0]?.[1]).toMatchObject({ method: "POST" })
    expect(JSON.parse(z.string().parse(fetcher.mock.calls[0]?.[1]?.body))).toEqual({
      from: "now-1h",
      to: "now",
      queries: [{ refId: "Q", expr: "up", datasource: { uid: "prom" } }]
    })
  })

  it("returns non-json bodies as text", async () => {
    const connected = await connect(respond(200, "plain text"))

    const result = await call(connected, "list_alerts", {})

    expect(toolText(result)).toBe('"plain text"')
  })

  it("reports Grafana failures, network errors and bad arguments as tool errors", async () => {
    const failing = await connect(respond(403, "permission denied"))
    const unreachable = await connect(
      vi.fn<Fetch>(async () => Promise.reject(new Error("ECONNREFUSED")))
    )

    const denied = await call(failing, "list_alerts")
    const offline = await call(unreachable, "list_alerts")
    const noUid = await call(failing, "get_alert_rule", {})
    const noQuery = await call(failing, "query", { datasourceUid: "prom" })
    const unknown = await call(failing, "delete_everything", {})

    expect(denied).toEqual({
      content: [{ type: "text", text: "Grafana returned 403: permission denied" }],
      isError: true
    })
    expect(offline).toEqual({
      content: [{ type: "text", text: "Grafana request failed: Error: ECONNREFUSED" }],
      isError: true
    })
    expect([noUid.isError, noQuery.isError]).toEqual([true, true])
    expect(toolText(unknown)).toBe("Unknown tool: delete_everything")
  })

  it("requires an account with a valid url and token", async () => {
    const fetcher = respond(200, "{}")
    const connected = await connect(fetcher)

    const missing = await call(connected, "list_alerts", {}, {})
    const invalid = await call(
      connected,
      "list_alerts",
      {},
      withAccount("acct-1", { url: "not a url", token: "t" })
    )

    expect(missing.isError).toBe(true)
    expect(toolText(invalid)).toBe("A Grafana account with a url and token is required.")
    expect(fetcher).not.toHaveBeenCalled()
  })
})
