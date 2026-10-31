import { expect, it } from "vitest"

import { inboxDevice, sealedInboxItem } from "../../infra/cloud-inbox-test-support.js"
import { makeCloudInbox } from "../../infra/cloud-inbox.js"
import { jsonRequest } from "../../test-support.js"
import { fakeCloud, startPluginApp } from "../plugin-test-support.js"
import { capabilitiesWith, savePluginRow } from "./plugin-events-test-support.js"

const grafanaId = "dev.codevisor/grafana"

const relayedWebhook = (itemId: string, inboxId: string) =>
  sealedInboxItem(itemId, "webhook", {
    itemId,
    inboxId,
    method: "POST",
    headers: { "content-type": "application/json" },
    body: Buffer.from("{}").toString("base64"),
    receivedAt: "2026-10-27T09:00:00.000Z"
  })

it("hands relayed webhooks to the plugin that provisioned the inbox, ignoring other inboxes", async () => {
  const { cloud } = fakeCloud((method, path) =>
    method === "POST" && path === "/api/machine/inboxes"
      ? { id: "inbox-1", url: "https://in.example/i/1" }
      : {}
  )
  const inbox = makeCloudInbox()
  const running = await startPluginApp({ cloud, inbox })
  const grafana = await savePluginRow(running.services.db, "Grafana", {
    catalogId: grafanaId,
    enabled: false,
    capabilities: capabilitiesWith({ ingress: [{ name: "alerts" }] })
  })
  const account = await running.platform.accounts.saveFields(grafana.id, {
    values: { url: "https://grafana.example.com", token: "glsa_secret" }
  })
  const webhooks: Array<{ serverId: string; accountId: string | undefined }> = []
  Object.assign(running.mcp, {
    pluginConnection: async (serverId: string) => ({
      request: async (method: string, _params: unknown, options?: { accountId?: string }) => {
        if (method === "codevisor/webhook")
          webhooks.push({ serverId, accountId: options?.accountId })
        return {}
      }
    })
  })
  await jsonRequest(running.server, `/v1/plugins/${grafana.id}/accounts/${account.id}/ingress`)

  await inbox.receive(inboxDevice.secretKey, relayedWebhook("item-1", "inbox-unknown"))
  await inbox.receive(inboxDevice.secretKey, relayedWebhook("item-2", "inbox-1"))

  expect(webhooks).toEqual([{ serverId: grafana.id, accountId: account.id }])
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

it("keeps a routed ingress out of the paste list and deletes an account's inboxes when it's removed", async () => {
  const { cloud, requests } = fakeCloud((_method, path) =>
    path.split("?")[0] === "/api/machine/inboxes"
      ? { id: "inbox-1", url: "https://in.example/i/1" }
      : {}
  )
  const running = await startPluginApp({ cloud, inbox: makeCloudInbox() })
  const grafana = await savePluginRow(running.services.db, "Grafana", {
    catalogId: grafanaId,
    enabled: false,
    capabilities: capabilitiesWith({ ingress: [{ name: "push", route: "gmail" }] })
  })
  const account = await running.platform.accounts.saveFields(grafana.id, {
    values: { url: "https://grafana.example.com", token: "glsa_secret" }
  })

  const listed = await jsonRequest(
    running.server,
    `/v1/plugins/${grafana.id}/accounts/${account.id}/ingress`
  )
  requests.splice(0)
  await running.platform.accounts.remove(grafana.id, account.id)

  expect([listed.status, listed.body]).toEqual([200, { ingress: [] }])
  expect(requests.map((request) => `${request.method} ${request.path}`)).toEqual([
    `GET /api/machine/inboxes?plugin=${encodeURIComponent(grafanaId)}&accountId=${account.id}&ingress=push`,
    "DELETE /api/machine/inboxes/inbox-1"
  ])
})
