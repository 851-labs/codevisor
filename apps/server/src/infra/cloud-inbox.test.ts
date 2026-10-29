import { describe, expect, it } from "vitest"

import { inboxDevice as device, sealedInboxItem as sealed } from "./cloud-inbox-test-support.js"
import {
  inboxFrameHandler,
  machineApiRequest,
  makeCloudInbox,
  MachineApiError,
  type InboxWebhookRequest
} from "./cloud-inbox.js"

const webhook = (itemId: string) =>
  sealed(itemId, "webhook", {
    itemId,
    inboxId: "inbox-1",
    method: "POST",
    headers: { "content-type": "application/json", "x-retries": 3 },
    body: "e30=",
    receivedAt: "2026-10-27T09:00:00.000Z"
  })

const recordingInbox = () => {
  const inbox = makeCloudInbox()
  const webhooks: Array<InboxWebhookRequest> = []
  const stopWebhooks = inbox.onWebhook(async (request) => {
    webhooks.push(request)
  })
  return { inbox, webhooks, stopWebhooks }
}

describe("cloud inbox", () => {
  it("opens sealed webhooks once, keeping only string headers", async () => {
    const { inbox, webhooks } = recordingInbox()

    await inbox.receive(device.secretKey, webhook("item-1"))
    await inbox.receive(device.secretKey, webhook("item-1"))

    expect(webhooks).toEqual([
      {
        itemId: "item-1",
        inboxId: "inbox-1",
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "e30=",
        receivedAt: "2026-10-27T09:00:00.000Z"
      }
    ])
  })

  it("drops items whose sealed payload isn't the expected shape", async () => {
    const { inbox, webhooks } = recordingInbox()

    await inbox.receive(device.secretKey, sealed("w1", "webhook", { itemId: "w1", method: "POST" }))
    await inbox.receive(device.secretKey, sealed("w2", "webhook", ["not", "a", "request"]))
    await inbox.receive(device.secretKey, sealed("o1", "oauth", { flowId: "f1", state: "s1" }))
    await inbox.receive(
      device.secretKey,
      sealed("w3", "webhook", { ...webhookPayload(), headers: "none" })
    )

    expect(webhooks.map((request) => request.headers)).toEqual([{}])
  })

  it("stops delivering to a handler once it unsubscribes", async () => {
    const { inbox, webhooks, stopWebhooks } = recordingInbox()

    stopWebhooks()
    await inbox.receive(device.secretKey, webhook("item-1"))

    expect(webhooks).toEqual([])
  })

  it("acknowledges an item only after it was handled, so a failed one comes back", async () => {
    const inbox = makeCloudInbox()
    const handled: Array<string> = []
    const failed = Promise.withResolvers<void>()
    let failures = 1
    inbox.onWebhook(async (request) => {
      if (failures > 0) {
        failures -= 1
        failed.resolve()
        throw new Error("plugin offline")
      }
      handled.push(request.itemId)
    })
    const acks: Array<ReadonlyArray<string>> = []
    const acked = Promise.withResolvers<void>()
    const handleFrame = inboxFrameHandler(inbox, device.secretKey, (itemIds) => {
      acks.push(itemIds)
      acked.resolve()
    })

    handleFrame(webhook("item-1"))
    await failed.promise
    handleFrame(webhook("item-1"))
    await acked.promise

    expect(handled).toEqual(["item-1"])
    expect(acks).toEqual([["item-1"]])
  })

  it("ignores frames when this server has no inbox", () => {
    const acks: Array<ReadonlyArray<string>> = []

    inboxFrameHandler(undefined, device.secretKey, (itemIds) => acks.push(itemIds))(
      webhook("item-1")
    )

    expect(acks).toEqual([])
  })

  it("forgets the oldest delivered items so memory stays bounded", async () => {
    const { inbox, webhooks } = recordingInbox()
    const frames = Array.from({ length: 2_001 }, (_, index) => webhook(`item-${index}`))

    for (const frame of frames) await inbox.receive(device.secretKey, frame)
    await inbox.receive(device.secretKey, frames[1]!)
    await inbox.receive(device.secretKey, frames[0]!)

    expect(webhooks.map((request) => request.itemId).slice(-2)).toEqual(["item-2000", "item-0"])
  })
})

const webhookPayload = () => ({
  itemId: "w3",
  inboxId: "inbox-1",
  method: "POST",
  body: "",
  receivedAt: "2026-10-27T09:00:00.000Z"
})

const recordingFetch = (status: number, text: string) => {
  const calls: Array<{ readonly url: string; readonly init: RequestInit | undefined }> = []
  const fetchImpl = async (url: string, init?: RequestInit) => {
    calls.push({ url, init })
    return new Response(text, { status })
  }
  return { calls, fetchImpl }
}
const credentials = { serverUrl: "https://cloud.example//", apiKey: "machine-key" }

describe("machine API requests", () => {
  it("sends JSON bodies with the machine key and parses the reply", async () => {
    const { calls, fetchImpl } = recordingFetch(200, '{"id":"inbox-1"}')

    const reply = await machineApiRequest(fetchImpl, credentials, {
      method: "POST",
      path: "/api/machine/inboxes",
      body: { plugin: "grafana" }
    })

    expect(reply).toEqual({ id: "inbox-1" })
    expect(calls).toEqual([
      {
        url: "https://cloud.example/api/machine/inboxes",
        init: {
          method: "POST",
          headers: { "x-api-key": "machine-key", "content-type": "application/json" },
          body: '{"plugin":"grafana"}'
        }
      }
    ])
  })

  it("treats an empty reply as no value and sends no body when there is none", async () => {
    const { calls, fetchImpl } = recordingFetch(200, "")

    const reply = await machineApiRequest(fetchImpl, credentials, {
      method: "PUT",
      path: "/api/machine/inboxes/inbox-1/devices/self"
    })

    expect(reply).toBeUndefined()
    expect(calls[0]?.init).toEqual({ method: "PUT", headers: { "x-api-key": "machine-key" } })
  })

  it("reports the status and the start of the cloud's explanation on failure", async () => {
    const { fetchImpl } = recordingFetch(403, `forbidden ${"x".repeat(300)}`)

    const failing = machineApiRequest(fetchImpl, credentials, {
      method: "GET",
      path: "/api/machine/inboxes"
    })

    await expect(failing).rejects.toBeInstanceOf(MachineApiError)
    await expect(failing).rejects.toMatchObject({
      status: 403,
      message: `Cloud request failed (403): forbidden ${"x".repeat(190)}`
    })
  })
})
