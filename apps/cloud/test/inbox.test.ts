import { env, SELF } from "cloudflare:test"
import { describe, expect, it } from "vitest"

import { inboxIngress } from "../src/inbox-ingress.js"
import { inboxRoutes } from "../src/inbox-routes.js"
import { INBOXES_OFF } from "../src/inbox-store.js"
import { BASE, devLogin, disconnect } from "./cloud-test-support.js"
import {
  connectInboxMachine,
  createInbox,
  InboxBody,
  machineIdentity,
  newInboxMachine,
  nextInboxItem,
  openInboxItem,
  openWebhookItem,
  postWebhook,
  provisionTestInbox,
  queuedCount,
  signUpUser,
  subscribe,
  subscription
} from "./inbox-test-support.js"
import { readJson } from "./json-test-support.js"

const webhookBody = JSON.stringify({ status: "firing", alerts: [{ fingerprint: "abc" }] })
const base64 = (text: string): string => btoa(text)

describe("inbox provisioning", () => {
  it("returns the same inbox for the same plugin, account and ingress", async () => {
    const machine = await machineIdentity(await devLogin())
    const target = { plugin: "grafana", accountId: crypto.randomUUID(), ingress: "alerts" }

    const first = await readJson(await createInbox(machine.apiKey, target), InboxBody)
    const second = await readJson(await createInbox(machine.apiKey, target), InboxBody)
    const other = await readJson(
      await createInbox(machine.apiKey, { ...target, ingress: "silences" }),
      InboxBody
    )

    expect(first.id).toMatch(/^[A-Za-z0-9_-]{22}$/)
    expect(first.url).toBe(`${BASE}/hooks/i/${first.id}`)
    expect(second).toEqual(first)
    expect(other.id).not.toBe(first.id)
  })

  it("requires a machine credential and a complete target", async () => {
    const machine = await machineIdentity(await devLogin())

    expect(
      (await createInbox("invalid", { plugin: "p", accountId: "", ingress: "i" })).status
    ).toBe(401)
    expect((await createInbox(machine.apiKey, { plugin: "p", ingress: "i" })).status).toBe(400)
    expect(
      (await createInbox(machine.apiKey, { plugin: "", accountId: "", ingress: "i" })).status
    ).toBe(400)
    expect(
      (await createInbox(machine.apiKey, { plugin: "p", accountId: "", ingress: "i" })).status
    ).toBe(200)
  })

  it("keeps another account's machines away from an inbox", async () => {
    const owner = await machineIdentity(await devLogin())
    const stranger = await machineIdentity(await signUpUser())
    const inbox = await provisionTestInbox(owner.apiKey)

    expect((await subscription(stranger.apiKey, inbox.id, "PUT")).status).toBe(404)
    expect((await subscription(stranger.apiKey, inbox.id, "DELETE")).status).toBe(404)
    const revoke = await SELF.fetch(`${BASE}/api/machine/inboxes/${inbox.id}`, {
      method: "DELETE",
      headers: { "x-api-key": stranger.apiKey }
    })
    expect(revoke.status).toBe(404)
  })

  it("refuses to subscribe a machine that never connected to the hub", async () => {
    const machine = await machineIdentity(await devLogin())
    const inbox = await provisionTestInbox(machine.apiKey)

    expect((await subscription(machine.apiKey, inbox.id, "PUT")).status).toBe(409)
  })
})

describe("inbox ingress", () => {
  it("seals each request to every subscribed device", async () => {
    const token = await devLogin()
    const [a, b] = [await newInboxMachine(token), await newInboxMachine(token)]
    const inbox = await provisionTestInbox(a.apiKey)
    await subscribe(a, inbox.id)
    await subscribe(b, inbox.id)

    const response = await postWebhook(inbox.url, webhookBody, {
      "content-type": "application/json",
      "X-Grafana-Signature": "sig",
      cookie: "session=secret",
      "proxy-authorization": "Basic secret"
    })
    expect(response.status).toBe(202)

    const [frameA, frameB] = [await nextInboxItem(a.reader), await nextInboxItem(b.reader)]
    expect(frameA).toMatchObject({ kind: "webhook", itemId: frameB.itemId })
    expect(frameA.sealed).not.toBe(frameB.sealed)
    const item = openInboxItem(a, frameA)
    expect(item).toEqual({
      itemId: frameA.itemId,
      inboxId: inbox.id,
      method: "POST",
      headers: expect.objectContaining({
        "content-type": "application/json",
        "x-grafana-signature": "sig"
      }),
      body: base64(webhookBody),
      receivedAt: "2100-01-01T00:00:00.000Z"
    })
    expect(openInboxItem(b, frameB)).toEqual(item)
    const headers = Object.keys(openWebhookItem(a, frameA).headers)
    expect(headers).not.toContain("cookie")
    expect(headers).not.toContain("proxy-authorization")
    expect(() => openInboxItem(b, frameA)).toThrow()
  })

  it("accepts the same inbox on the hooks host path", async () => {
    const token = await devLogin()
    const machine = await newInboxMachine(token)
    const inbox = await provisionTestInbox(machine.apiKey)
    await subscribe(machine, inbox.id)

    expect((await postWebhook(`${BASE}/i/${inbox.id}`, "{}")).status).toBe(202)
    expect(openInboxItem(machine, await nextInboxItem(machine.reader))).toMatchObject({
      inboxId: inbox.id,
      body: base64("{}")
    })
  })

  it("deletes only the acking device's copy", async () => {
    const token = await devLogin()
    const [a, b] = [await newInboxMachine(token), await newInboxMachine(token)]
    const inbox = await provisionTestInbox(a.apiKey)
    await subscribe(a, inbox.id)
    await subscribe(b, inbox.id)
    expect((await postWebhook(inbox.url, webhookBody)).status).toBe(202)
    const frame = await nextInboxItem(a.reader)

    a.socket.send(JSON.stringify({ t: "inbox-ack", itemIds: [frame.itemId] }))
    await disconnect(token, a.socket, "acked")
    await disconnect(token, b.socket, "not acked")

    expect(await queuedCount(token, a.deviceId)).toBe(0)
    expect(await queuedCount(token, b.deviceId)).toBe(1)
    const reconnected = await connectInboxMachine(b)
    expect((await nextInboxItem(reconnected.reader)).itemId).toBe(frame.itemId)
  })

  it("holds items for an offline device and flushes them on connect", async () => {
    const token = await devLogin()
    const machine = await newInboxMachine(token)
    const inbox = await provisionTestInbox(machine.apiKey)
    await subscribe(machine, inbox.id)
    await disconnect(token, machine.socket, "asleep")

    expect((await postWebhook(inbox.url, "first")).status).toBe(202)
    expect((await postWebhook(inbox.url, "second")).status).toBe(202)

    const awake = await connectInboxMachine(machine)
    const bodies = [await nextInboxItem(awake.reader), await nextInboxItem(awake.reader)].map(
      (frame) => openWebhookItem(machine, frame).body
    )
    expect(bodies).toEqual([base64("first"), base64("second")])
  })

  it("stops queueing for a device that unsubscribes", async () => {
    const token = await devLogin()
    const [a, b] = [await newInboxMachine(token), await newInboxMachine(token)]
    const inbox = await provisionTestInbox(a.apiKey)
    await subscribe(a, inbox.id)
    await subscribe(b, inbox.id)
    await disconnect(token, b.socket, "offline")
    expect((await postWebhook(inbox.url, "before")).status).toBe(202)
    expect(await queuedCount(token, b.deviceId)).toBe(1)

    expect((await subscription(b.apiKey, inbox.id, "DELETE")).status).toBe(200)
    expect((await postWebhook(inbox.url, "after")).status).toBe(202)

    expect(await queuedCount(token, b.deviceId)).toBe(0)
  })

  it("answers 404 for unknown and revoked inboxes", async () => {
    const token = await devLogin()
    const machine = await newInboxMachine(token)
    const inbox = await provisionTestInbox(machine.apiKey)
    await subscribe(machine, inbox.id)
    await disconnect(token, machine.socket, "offline")
    expect((await postWebhook(inbox.url, "queued")).status).toBe(202)

    const revoke = () =>
      SELF.fetch(`${BASE}/api/machine/inboxes/${inbox.id}`, {
        method: "DELETE",
        headers: { "x-api-key": machine.apiKey }
      })
    expect((await revoke()).status).toBe(200)

    expect((await postWebhook(inbox.url, "late")).status).toBe(404)
    expect((await postWebhook(`${BASE}/hooks/i/unknown-inbox`, "x")).status).toBe(404)
    expect((await revoke()).status).toBe(404)
    expect((await subscription(machine.apiKey, inbox.id, "PUT")).status).toBe(404)
    expect(await queuedCount(token, machine.deviceId)).toBe(0)
  })

  it("rejects bodies over 256 KiB", async () => {
    const machine = await machineIdentity(await devLogin())
    const inbox = await provisionTestInbox(machine.apiKey)

    expect((await postWebhook(inbox.url, "x".repeat(256 * 1024 + 1))).status).toBe(413)
    expect((await postWebhook(inbox.url, "x".repeat(256 * 1024))).status).toBe(202)
  })
})

describe("MCP webhook receiver discovery", () => {
  it("publishes the inbox paths as MCP webhook receivers", async () => {
    const response = await SELF.fetch(`${BASE}/.well-known/mcp-webhook-receiver.json`)
    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({ receivers: ["/i/", "/hooks/i/"] })
  })
})

describe("webhook inboxes without HOOKS_BASE_URL", () => {
  const unconfigured = { ...env, HOOKS_BASE_URL: undefined }

  it("refuses to hand out an inbox and says why", async () => {
    const machine = await machineIdentity(await devLogin())

    const response = await inboxRoutes.request(
      `${BASE}/api/machine/inboxes`,
      {
        method: "POST",
        headers: { "x-api-key": machine.apiKey, "content-type": "application/json" },
        body: JSON.stringify({ plugin: "alerts", accountId: "a", ingress: "alerts" })
      },
      unconfigured
    )

    expect(response.status).toBe(503)
    expect(await response.json()).toEqual({ error: INBOXES_OFF })
  })

  it("turns away webhook deliveries", async () => {
    const response = await inboxIngress.request(
      `${BASE}/hooks/i/any-inbox`,
      { method: "POST", body: "{}" },
      unconfigured
    )

    expect(response.status).toBe(503)
    expect(await response.json()).toEqual({ error: INBOXES_OFF })
  })
})
