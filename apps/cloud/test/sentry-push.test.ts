import { env } from "cloudflare:test"
import { beforeAll, describe, expect, it } from "vitest"

import type { CloudEnv } from "../src/env.js"
import { SENTRY_WEBHOOKS_OFF } from "../src/inbox-route-configs.js"
import { MAX_ROUTE_KEYS } from "../src/inbox-routes.js"
import worker from "../src/index.js"
import { hmacSha256Hex, routeKeyOf } from "../src/webhook-relay.js"
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

const secret = "sentry_client_secret_test"
const acme = "1001"
const globex = "2002"

let sentryEnv: CloudEnv
let offEnv: CloudEnv

beforeAll(() => {
  sentryEnv = { ...env, SENTRY_WEBHOOK_SECRET: secret }
  offEnv = { ...env, SENTRY_WEBHOOK_SECRET: "" }
})

const installationFor = (organizationId: string) => `install-${organizationId}`

interface DeliveryOptions {
  readonly signedWith?: string
  readonly sentAt?: number
  readonly path?: string
  readonly cloudEnv?: CloudEnv
}

const deliver = async (resource: string, body: unknown, options: DeliveryOptions = {}) => {
  const raw = JSON.stringify(body)
  return worker.fetch(
    new Request(`${BASE}${options.path ?? "/hooks/push/sentry"}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "sentry-hook-resource": resource,
        "sentry-hook-timestamp": String(Math.floor((options.sentAt ?? Date.now()) / 1000)),
        "sentry-hook-signature": await hmacSha256Hex(options.signedWith ?? secret, raw)
      },
      body: raw
    }),
    options.cloudEnv ?? sentryEnv
  )
}

const install = (organizationId: string, action = "created") =>
  deliver("installation", {
    action,
    installation: { uuid: installationFor(organizationId) },
    data: {
      installation: {
        uuid: installationFor(organizationId),
        status: "installed",
        organization: { id: Number(organizationId), slug: `org-${organizationId}` },
        app: { uuid: "app-uuid", slug: "codevisor" },
        code: "grant-code-never-relayed"
      }
    }
  })

const issueDelivery = (action: string, organizationId = acme, substatus = "new") => ({
  action,
  installation: { uuid: installationFor(organizationId) },
  actor: { type: "user", id: 7, name: "Sam" },
  data: {
    issue: {
      id: "4242",
      shortId: "WEB-1Z",
      title: "TypeError: secret customer payload",
      culprit: "app/checkout.ts",
      substatus,
      status: "unresolved"
    }
  }
})

const routeRequest = (apiKey: string, inboxId: string, body: unknown) =>
  new Request(`${BASE}/api/machine/inboxes/${inboxId}/routes/sentry`, {
    method: "PUT",
    headers: { "content-type": "application/json", "x-api-key": apiKey },
    body: JSON.stringify(body)
  })

const routedMachine = async (organizationIds: ReadonlyArray<string>) => {
  const token = await signUpUser()
  const machine = await newInboxMachine(token)
  const inbox = await provisionTestInbox(machine.apiKey)
  await subscribe(machine, inbox.id)
  const keys = await Promise.all(organizationIds.map(routeKeyOf))
  const routed = await worker.fetch(routeRequest(machine.apiKey, inbox.id, { keys }), sentryEnv)
  expect(routed.status).toBe(200)
  return { token, machine, inbox }
}

const relayedPing = async (
  machine: Awaited<ReturnType<typeof newInboxMachine>>
): Promise<unknown> =>
  JSON.parse(
    Buffer.from(
      openWebhookItem(machine, await nextInboxItem(machine.reader)).body,
      "base64"
    ).toString("utf8")
  )

describe("sentry webhook routes", () => {
  it("routes one inbox by several organizations, and is off without the client secret", async () => {
    const machine = await newInboxMachine(await signUpUser())
    const inbox = await provisionTestInbox(machine.apiKey)
    const keys = await Promise.all([acme, globex].map(routeKeyOf))
    const tooMany = Array.from({ length: MAX_ROUTE_KEYS + 1 }, () => keys[0])

    const routed = await worker.fetch(routeRequest(machine.apiKey, inbox.id, { keys }), sentryEnv)
    const rejected = await worker.fetch(
      routeRequest(machine.apiKey, inbox.id, { keys: tooMany }),
      sentryEnv
    )
    const off = await worker.fetch(routeRequest(machine.apiKey, inbox.id, { keys }), offEnv)

    expect([routed.status, rejected.status, off.status]).toEqual([200, 400, 503])
    expect(await off.json()).toEqual({ error: SENTRY_WEBHOOKS_OFF })
  })
})

describe("sentry webhook endpoint", () => {
  it("relays issue ids to every inbox routed for the installing organization", async () => {
    const { machine } = await routedMachine([globex, acme])
    await install(acme)

    const response = await deliver("issue", issueDelivery("unresolved", acme, "regressed"))
    const ping = await relayedPing(machine)

    expect(response.status).toBe(200)
    expect(ping).toEqual({
      organizationId: acme,
      action: "unresolved",
      resource: "issue",
      issueId: "4242",
      substatus: "regressed",
      timestamp: expect.any(String)
    })
    expect(JSON.stringify(ping)).not.toMatch(/secret|TypeError|checkout|grant/)
  })

  it("relays comments and alerts as ids and the alert's name", async () => {
    const { machine } = await routedMachine([acme])
    await install(acme)
    const uuid = { installation: { uuid: installationFor(acme) } }

    await deliver("comment", {
      ...uuid,
      action: "created",
      data: {
        comment: "private words",
        comment_id: 55,
        issue_id: 4242,
        project_slug: "web",
        timestamp: "2026-11-25T10:00:00Z"
      }
    })
    const comment = await relayedPing(machine)
    await deliver("event_alert", {
      ...uuid,
      action: "triggered",
      data: {
        event: { issue_id: "4242", event_id: "abc123", title: "private event title" },
        triggered_rule: "Checkout errors"
      }
    })
    const issueAlert = await relayedPing(machine)
    await deliver("metric_alert", {
      ...uuid,
      action: "critical",
      data: {
        description_title: "Critical: Too many errors",
        metric_alert: {
          id: "4",
          identifier: "17",
          alert_rule: { id: "7", name: "Too many errors" }
        }
      }
    })
    const metricAlert = await relayedPing(machine)

    expect(comment).toMatchObject({ resource: "comment", issueId: "4242", commentId: "55" })
    expect(JSON.stringify(comment)).not.toContain("private")
    expect(issueAlert).toMatchObject({
      resource: "event_alert",
      issueId: "4242",
      eventId: "abc123",
      alert: { rule: "Checkout errors", status: "triggered" }
    })
    expect(JSON.stringify(issueAlert)).not.toContain("private")
    expect(metricAlert).toMatchObject({
      resource: "metric_alert",
      alert: { rule: "Too many errors", status: "critical", incidentId: "17" }
    })
  })

  it("ignores deliveries from unknown or removed installations and unrelayed actions", async () => {
    const { token, machine } = await routedMachine([acme, globex])
    await install(globex)
    await install(globex, "deleted")

    const statuses = await Promise.all([
      deliver("issue", issueDelivery("created", globex)),
      deliver("issue", issueDelivery("created", "3003")),
      deliver("issue", issueDelivery("resolved", acme)),
      deliver("installation", { nope: true })
    ])

    expect(statuses.map((response) => response.status)).toEqual([200, 200, 200, 200])
    expect(await queuedCount(token, machine.deviceId)).toBe(0)
  })

  it("rejects unsigned, wrongly signed and stale deliveries, and is off without a secret", async () => {
    const { token, machine } = await routedMachine([acme])
    await install(acme)
    const body = issueDelivery("created")

    const unsigned = await worker.fetch(
      new Request(`${BASE}/push/sentry`, { method: "POST", body: JSON.stringify(body) }),
      sentryEnv
    )
    const forged = await deliver("issue", body, { signedWith: "someone-else" })
    const stale = await deliver("issue", body, { sentAt: Date.now() - 10 * 60_000 })
    const off = await deliver("issue", body, { cloudEnv: offEnv })

    expect([unsigned.status, forged.status, stale.status, off.status]).toEqual([401, 401, 401, 404])
    expect(await queuedCount(token, machine.deviceId)).toBe(0)
  })
})
