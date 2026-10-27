import { decode, McpServer, PluginAccount, PluginEventSubscription } from "@codevisor/api"
import { expect, it } from "vitest"

import { inboxDevice, sealedInboxItem } from "../../infra/cloud-inbox-test-support.js"
import { makeCloudInbox } from "../../infra/cloud-inbox.js"
import { jsonRequest, waitFor } from "../../test-support.js"
import { recordField, stringField } from "../../unknown-values.js"
import {
  createChat,
  fakeCloud,
  pluginEventPrompts,
  post,
  startPluginApp,
  startPluginServer,
  watchStreams,
  type CloudReply,
  type PluginServer
} from "../plugin-test-support.js"
import { capabilitiesWith, savePluginRow } from "./plugin-events-test-support.js"

const grafanaId = "dev.codevisor/grafana"

const inboxReply: CloudReply = (method, path, body) => {
  if (method !== "POST" || path !== "/api/machine/inboxes") return undefined
  const ingress = stringField(body, "ingress")
  return { id: `inbox-${ingress}`, url: `https://in.example/i/inbox-${ingress}` }
}

const installGrafana = async (running: PluginServer) => {
  const grafana = decode(McpServer)(
    (await post(running, `/v1/plugins/catalog/${encodeURIComponent(grafanaId)}/install`)).body
  )
  await waitFor(async () => {
    const listed = (await running.mcp.list()).find((server) => server.id === grafana.id)
    return (listed?.capabilities?.events.length ?? 0) > 0
  })
  return grafana
}

const alertWebhook = (
  inboxId: string,
  secret: string,
  alerts: ReadonlyArray<Record<string, unknown>>
) =>
  sealedInboxItem("item-1", "webhook", {
    itemId: "item-1",
    inboxId,
    method: "POST",
    headers: { authorization: `Bearer ${secret}`, "content-type": "application/json" },
    body: Buffer.from(JSON.stringify({ alerts })).toString("base64"),
    receivedAt: "2026-10-27T09:00:00.000Z"
  })

const alert = (fingerprint: string, severity: string) => ({
  status: "firing",
  labels: { alertname: `Disk ${severity}`, severity },
  fingerprint,
  startsAt: "2026-10-27T09:00:00Z"
})

it("wakes a chat from a Grafana webhook relayed through this Mac's cloud inbox", async () => {
  const { cloud, requests } = fakeCloud(inboxReply)
  const inbox = makeCloudInbox()
  const running = await startPluginServer({ cloud, inbox })
  const streams = watchStreams(running)
  const grafana = await installGrafana(running)
  const account = decode(PluginAccount)(
    (
      await post(running, `/v1/plugins/${grafana.id}/accounts`, {
        values: { url: "https://grafana.example.com", token: "glsa_secret" }
      })
    ).body
  )
  const meta = await running.platform.accountSource.meta(grafana.id)
  const webhookSecret = stringField(recordField(meta, "fields"), "webhookSecret")!
  const watcher = await createChat(running, "On call")

  const urls = await jsonRequest(
    running.server,
    `/v1/plugins/${grafana.id}/accounts/${account.id}/ingress`
  )
  const subscription = decode(PluginEventSubscription)(
    (
      await post(running, "/v1/plugins/events/subscriptions", {
        sessionId: watcher,
        plugin: "Grafana",
        event: "alert.firing",
        filter: 'labels.severity == "critical"'
      })
    ).body
  )
  await waitFor(() => streams.length > 0 && requests.some((request) => request.method === "PUT"))
  await inbox.receive(
    inboxDevice.secretKey,
    alertWebhook("inbox-alerts", webhookSecret, [
      alert("fp-info", "info"),
      alert("fp-critical", "critical")
    ])
  )
  await waitFor(() => pluginEventPrompts(running).length === 1)
  await jsonRequest(running.server, `/v1/plugins/events/subscriptions/${subscription.id}`, {
    method: "DELETE"
  })
  await waitFor(() => requests.some((request) => request.method === "DELETE"))

  expect(urls.body).toEqual({
    ingress: [
      { name: "alerts", title: "Grafana alert webhook", url: "https://in.example/i/inbox-alerts" }
    ]
  })
  expect(subscription.accountId).toBe(account.id)
  expect(pluginEventPrompts(running)[0]).toContain('account="grafana.example.com"')
  expect(pluginEventPrompts(running)[0]).toContain('"alertname":"Disk critical"')
  expect(
    requests
      .filter((request) => request.method !== "POST")
      .map((request) => `${request.method} ${request.path}`)
  ).toEqual([
    "PUT /api/machine/inboxes/inbox-alerts/devices/self",
    "DELETE /api/machine/inboxes/inbox-alerts/devices/self"
  ])
})

it("explains when the cloud doesn't hand out an inbox", async () => {
  const replies: ReadonlyArray<unknown> = [null, { id: 7 }]
  let asked = 0
  const { cloud } = fakeCloud(() => replies[asked++])
  const running = await startPluginApp({ cloud, inbox: makeCloudInbox() })
  const grafana = await savePluginRow(running.services.db, "Grafana", {
    catalogId: grafanaId,
    enabled: false,
    capabilities: capabilitiesWith({ ingress: [{ name: "alerts" }] })
  })

  const nothing = await jsonRequest(
    running.server,
    `/v1/plugins/${grafana.id}/accounts/account-1/ingress`
  )
  const noUrl = await jsonRequest(
    running.server,
    `/v1/plugins/${grafana.id}/accounts/account-1/ingress`
  )

  expect([nothing, noUrl].map((response) => [response.status, response.body])).toEqual([
    [500, { error: "The cloud didn't return an inbox" }],
    [500, { error: "The cloud didn't return an inbox" }]
  ])
})
