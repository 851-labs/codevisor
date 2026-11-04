import { env, SELF } from "cloudflare:test"
import { beforeAll, describe, expect, it } from "vitest"

import type { CloudEnv } from "../src/env.js"
import { LINEAR_WEBHOOKS_OFF } from "../src/inbox-route-configs.js"
import worker from "../src/index.js"
import { linearRouteKey, linearSignature } from "../src/linear-push.js"
import { BASE } from "./cloud-test-support.js"
import {
  newInboxMachine,
  nextInboxItem,
  openWebhookItem,
  provisionTestInbox,
  queuedCount,
  signUpUser,
  subscribe
} from "./inbox-test-support.js"

const secret = "lin_wh_test_secret"
const organizationId = "8f2c5a1e-0d7b-4c3a-9e61-2b4d7f9a0c11"

let linearEnv: CloudEnv
let offEnv: CloudEnv

beforeAll(() => {
  linearEnv = { ...env, LINEAR_WEBHOOK_SECRET: secret }
  offEnv = { ...env, LINEAR_WEBHOOK_SECRET: "" }
})

const issueUpdate = (overrides: Record<string, unknown> = {}) => ({
  action: "update",
  type: "Issue",
  organizationId,
  createdAt: "2026-11-04T20:00:00.000Z",
  webhookTimestamp: Date.now(),
  webhookId: "wh-1",
  url: "https://linear.app/acme/issue/ENG-1/launch",
  actor: { id: "user-2", type: "user", name: "Sam", email: "sam@acme.com" },
  data: {
    id: "issue-1",
    identifier: "ENG-1",
    title: "Launch",
    description: "Private plans",
    updatedAt: "2026-11-04T20:00:00.000Z",
    stateId: "state-done"
  },
  updatedFrom: {
    stateId: "state-todo",
    assigneeId: null,
    priority: 3,
    title: "Old secret title",
    updatedAt: "2026-11-04T19:00:00.000Z"
  },
  ...overrides
})

const deliver = async (
  body: unknown,
  { signedWith = secret, path = "/push/linear", cloudEnv = linearEnv } = {}
) => {
  const raw = JSON.stringify(body)
  return worker.fetch(
    new Request(`${BASE}${path}`, {
      method: "POST",
      headers: {
        "content-type": "application/json; charset=utf-8",
        "linear-signature": await linearSignature(signedWith, raw)
      },
      body: raw
    }),
    cloudEnv
  )
}

const routeRequest = (apiKey: string, inboxId: string, body: unknown) =>
  new Request(`${BASE}/api/machine/inboxes/${inboxId}/routes/linear`, {
    method: "PUT",
    headers: { "content-type": "application/json", "x-api-key": apiKey },
    body: JSON.stringify(body)
  })

const routedMachine = async () => {
  const token = await signUpUser()
  const machine = await newInboxMachine(token)
  const inbox = await provisionTestInbox(machine.apiKey)
  await subscribe(machine, inbox.id)
  const key = await linearRouteKey(organizationId)
  expect(
    (await worker.fetch(routeRequest(machine.apiKey, inbox.id, { key }), linearEnv)).status
  ).toBe(200)
  return { token, machine, inbox }
}

const relayedPing = (
  machine: Awaited<ReturnType<typeof newInboxMachine>>,
  frame: Awaited<ReturnType<typeof nextInboxItem>>
): unknown =>
  JSON.parse(Buffer.from(openWebhookItem(machine, frame).body, "base64").toString("utf8"))

describe("linear webhook routes", () => {
  it("routes an inbox by its workspace hash, and is off without a signing secret", async () => {
    const machine = await newInboxMachine(await signUpUser())
    const inbox = await provisionTestInbox(machine.apiKey)
    const key = await linearRouteKey(organizationId)

    const routed = await worker.fetch(routeRequest(machine.apiKey, inbox.id, { key }), linearEnv)
    const off = await worker.fetch(routeRequest(machine.apiKey, inbox.id, { key }), offEnv)

    expect(routed.status).toBe(200)
    expect(await routed.json()).toEqual({ config: {} })
    expect(off.status).toBe(503)
    expect(await off.json()).toEqual({ error: LINEAR_WEBHOOKS_OFF })
  })
})

describe("linear webhook endpoint", () => {
  it("relays ids, changed field names and previous ids, never titles or descriptions", async () => {
    const { machine } = await routedMachine()

    const response = await deliver(issueUpdate())
    const ping = relayedPing(machine, await nextInboxItem(machine.reader))

    expect(response.status).toBe(200)
    expect(ping).toEqual({
      organizationId,
      type: "Issue",
      action: "update",
      id: "issue-1",
      createdAt: "2026-11-04T20:00:00.000Z",
      updatedAt: "2026-11-04T20:00:00.000Z",
      actorId: "user-2",
      changed: ["stateId", "assigneeId", "priority", "title", "updatedAt"],
      previous: { stateId: "state-todo", assigneeId: null, priority: 3 }
    })
    expect(JSON.stringify(ping)).not.toMatch(/secret|Private|Launch/)
  })

  it("relays new issues and comments on the hooks path, to that workspace only", async () => {
    const { token, machine } = await routedMachine()
    const created = {
      action: "create",
      type: "Comment",
      organizationId,
      createdAt: "2026-11-04T20:01:00.000Z",
      webhookTimestamp: Date.now(),
      data: {
        id: "comment-1",
        body: "hi",
        issueId: "issue-1",
        updatedAt: "2026-11-04T20:01:00.000Z"
      }
    }

    const elsewhere = await deliver({ ...created, organizationId: "other-org" })
    const hooksPath = await deliver(created, { path: "/hooks/push/linear" })
    const ping = relayedPing(machine, await nextInboxItem(machine.reader))

    expect([elsewhere.status, hooksPath.status]).toEqual([200, 200])
    expect(ping).toMatchObject({ type: "Comment", action: "create", id: "comment-1", changed: [] })
    expect(await queuedCount(token, machine.deviceId)).toBe(1)
  })

  it("rejects unsigned, wrongly signed and stale deliveries", async () => {
    const { token, machine } = await routedMachine()
    const raw = JSON.stringify(issueUpdate())

    const unsigned = await worker.fetch(
      new Request(`${BASE}/push/linear`, { method: "POST", body: raw }),
      linearEnv
    )
    const forged = await deliver(issueUpdate(), { signedWith: "someone-else" })
    const stale = await deliver(issueUpdate({ webhookTimestamp: Date.now() - 5 * 60_000 }))

    expect([unsigned.status, forged.status, stale.status]).toEqual([401, 401, 401])
    expect(await queuedCount(token, machine.deviceId)).toBe(0)
  })

  it("acknowledges deliveries it doesn't relay, so Linear keeps the webhook on", async () => {
    const { token, machine } = await routedMachine()

    const statuses = await Promise.all([
      deliver(issueUpdate({ action: "remove" })),
      deliver(issueUpdate({ type: "Reaction" })),
      deliver({ nope: true })
    ])

    expect(statuses.map((response) => response.status)).toEqual([200, 200, 200])
    expect(await queuedCount(token, machine.deviceId)).toBe(0)
  })

  it("stops routing to an inbox once it's deleted, and is off without a signing secret", async () => {
    const { token, machine, inbox } = await routedMachine()

    const deleted = await SELF.fetch(`${BASE}/api/machine/inboxes/${inbox.id}`, {
      method: "DELETE",
      headers: { "x-api-key": machine.apiKey }
    })
    const response = await deliver(issueUpdate())
    const off = await deliver(issueUpdate(), { cloudEnv: offEnv })

    expect([deleted.status, response.status, off.status]).toEqual([200, 200, 404])
    expect(await queuedCount(token, machine.deviceId)).toBe(0)
  })
})
