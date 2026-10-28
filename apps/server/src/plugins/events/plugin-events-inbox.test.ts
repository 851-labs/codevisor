import { expect, it } from "vitest"

import { inboxDevice, sealedInboxItem } from "../../infra/cloud-inbox-test-support.js"
import { makeCloudInbox } from "../../infra/cloud-inbox.js"
import { jsonRequest } from "../../test-support.js"
import {
  fakeCloud,
  pluginEventPrompts,
  startPluginApp,
  startPluginServer
} from "../plugin-test-support.js"
import { capabilitiesWith, savePluginRow } from "./plugin-events-test-support.js"

const grafanaId = "dev.codevisor/grafana"

it("ignores webhooks relayed for inboxes this Mac never handed out", async () => {
  const inbox = makeCloudInbox()
  const running = await startPluginServer({ cloud: fakeCloud().cloud, inbox })

  await inbox.receive(
    inboxDevice.secretKey,
    sealedInboxItem("item-1", "webhook", {
      itemId: "item-1",
      inboxId: "inbox-unknown",
      method: "POST",
      headers: { "content-type": "application/json" },
      body: Buffer.from("{}").toString("base64"),
      receivedAt: "2026-10-27T09:00:00.000Z"
    })
  )

  expect(pluginEventPrompts(running)).toEqual([])
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
