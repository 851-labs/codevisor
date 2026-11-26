import { anyResult } from "@codevisor/plugin-kit/test-support"
import type { Notification } from "@modelcontextprotocol/server"
import { describe, expect, it, vi } from "vitest"

import { pollIntervalMs } from "./sentry-poll.js"
import {
  accountFor,
  activity,
  type ConnectedSentry,
  connectSentry,
  fakeIssue,
  me,
  myTeam,
  openSentryStream,
  sam,
  start
} from "./sentry-test-support.js"

const eventsOf = (notifications: ReadonlyArray<Notification>) =>
  notifications
    .filter((notification) => notification.method === "notifications/events/event")
    .map((notification) => notification.params)

const delivered = (connected: ConnectedSentry, subscriptionId: unknown) =>
  eventsOf(connected.inbox.forSubscription(subscriptionId))

const pollOnce = async (connected: ConnectedSentry, searches: number) => {
  const before = connected.sentry.searches.length
  connected.clock.advance(pollIntervalMs)
  await vi.waitFor(() =>
    expect(connected.sentry.searches.length).toBeGreaterThanOrEqual(before + searches)
  )
}

const at = (offsetMs: number) => new Date(start + offsetMs).toISOString()

const acmePayload = { id: "101", slug: "acme", name: "Acme" }

describe("sentry events", () => {
  it("declares typed push events and a routed Sentry webhook ingress", async () => {
    const { client } = await connectSentry()

    const listed = await client.request({ method: "events/list" }, anyResult)

    expect(client.getServerCapabilities()?.extensions).toMatchObject({
      "dev.codevisor/webhooks": { ingress: [{ name: "sentry", route: "sentry" }] }
    })
    expect(listed.events).toMatchObject(
      [
        "issue.created",
        "issue.regressed",
        "issue.escalating",
        "issue.assigned",
        "comment.created",
        "alert.fired"
      ].map((name) => ({ name, delivery: ["push"], payloadSchema: { type: "object" } }))
    )
  })

  it("opens a stream only with an account Sentry accepts", async () => {
    const { client } = await connectSentry()
    const stream = (meta: Record<string, unknown>) =>
      client.request(
        {
          method: "events/stream",
          params: { name: "issue.created", arguments: {}, cursor: null, _meta: meta }
        },
        anyResult
      )

    await expect(stream({})).rejects.toMatchObject({ code: -32024 })
    await expect(stream(accountFor("sntryu_revoked"))).rejects.toMatchObject({ code: -32024 })
  })

  it("polls every organization for new issues", async () => {
    const connected = await connectSentry()
    const created = await openSentryStream(connected, "issue.created")
    connected.sentry.issues.set("4242", fakeIssue())

    await pollOnce(connected, 2)

    await vi.waitFor(() =>
      expect(delivered(connected, created.subscriptionId)).toMatchObject([
        {
          eventId: "issue.created:4242",
          name: "issue.created",
          timestamp: at(60_000),
          data: {
            organization: acmePayload,
            issue: {
              id: "4242",
              shortId: "WEB-1Z",
              culprit: "app/checkout.ts in submitOrder",
              url: "https://acme.sentry.io/issues/4242/",
              project: { slug: "web" },
              count: 3,
              assignee: null
            }
          }
        }
      ])
    )
    expect(connected.sentry.searches).toEqual([
      "acme firstSeen:>2026-11-25T11:58:00",
      "globex firstSeen:>2026-11-25T11:58:00"
    ])
  })

  it("polls regressions and assignments, reading only the issues that changed", async () => {
    const connected = await connectSentry()
    connected.sentry.issues.set(
      "1",
      fakeIssue({
        id: "1",
        substatus: "regressed",
        activity: [activity({ id: "500", type: "set_regression", dateCreated: at(-3_600_000) })]
      })
    )
    const regressed = await openSentryStream(connected, "issue.regressed")
    const assigned = await openSentryStream(connected, "issue.assigned")
    await pollOnce(connected, 4)
    connected.sentry.issues.set(
      "2",
      fakeIssue({
        id: "2",
        substatus: "regressed",
        lastSeen: at(45_000),
        activity: [
          activity({
            id: "501",
            type: "set_regression",
            dateCreated: at(40_000),
            data: { version: "web@1.4.2" }
          })
        ]
      })
    )
    connected.sentry.issues.set(
      "3",
      fakeIssue({
        id: "3",
        assignedTo: { type: "team", id: myTeam.id, name: "Web" },
        activity: [
          activity({
            id: "502",
            type: "assigned",
            user: sam,
            data: { assignee: myTeam.id, assigneeType: "team" }
          })
        ]
      })
    )

    await pollOnce(connected, 4)
    await vi.waitFor(() => expect(delivered(connected, assigned.subscriptionId)).toHaveLength(1))
    await pollOnce(connected, 4)

    expect(delivered(connected, regressed.subscriptionId)).toMatchObject([
      {
        eventId: "issue.regressed:501",
        data: { organization: acmePayload, issue: { id: "2" }, release: "web@1.4.2" }
      }
    ])
    expect(delivered(connected, assigned.subscriptionId)).toMatchObject([
      {
        eventId: "issue.assigned:502",
        data: {
          issue: { id: "3", assignee: { type: "team", id: myTeam.id, name: "Web" } },
          assignee: { type: "team", id: myTeam.id, name: "Web" },
          toMe: false,
          toMyTeam: true,
          byMe: false
        }
      }
    ])
    expect(connected.sentry.detailReads.toSorted()).toEqual(["2", "3"])
  })
})

const receive = (connected: ConnectedSentry, fields: Record<string, unknown>, ingress?: string) =>
  connected.client.request(
    { method: "codevisor/webhook", params: webhookParams(fields, ingress) },
    anyResult
  )

const webhookParams = (fields: Record<string, unknown>, ingress = "sentry") => ({
  ingress,
  request: {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: Buffer.from(
      JSON.stringify({ organizationId: "101", timestamp: at(5_000), ...fields })
    ).toString("base64"),
    receivedAt: at(5_000)
  },
  _meta: accountFor()
})

describe("sentry webhooks", () => {
  it("turns relayed issue changes into events at once", async () => {
    const connected = await connectSentry()
    connected.sentry.issues.set(
      "4242",
      fakeIssue({
        substatus: "escalating",
        assignedTo: { type: "user", id: me.id, name: "Dana" },
        activity: [
          activity({ id: "600", type: "set_regression" }),
          activity({ id: "601", type: "set_escalating" }),
          activity({ id: "602", type: "assigned", data: { assignee: me.id, assigneeType: "user" } })
        ]
      })
    )
    const streams = await Promise.all(
      ["issue.created", "issue.regressed", "issue.escalating", "issue.assigned"].map((name) =>
        openSentryStream(connected, name)
      )
    )

    const outcomes = await Promise.all([
      receive(connected, { resource: "issue", action: "created", issueId: "4242" }),
      receive(connected, {
        resource: "issue",
        action: "unresolved",
        issueId: "4242",
        substatus: "regressed"
      }),
      receive(connected, {
        resource: "issue",
        action: "unresolved",
        issueId: "4242",
        substatus: "escalating"
      }),
      receive(connected, { resource: "issue", action: "assigned", issueId: "4242" })
    ])

    expect(outcomes).toEqual(Array.from({ length: 4 }, () => ({ accepted: 1, status: 200 })))
    expect(
      streams.map((stream) => delivered(connected, stream.subscriptionId)[0]?.eventId)
    ).toEqual([
      "issue.created:4242",
      "issue.regressed:600",
      "issue.escalating:601",
      "issue.assigned:602"
    ])
    expect(delivered(connected, streams[3]?.subscriptionId)[0]?.data).toMatchObject({
      toMe: true,
      toMyTeam: false,
      byMe: false
    })
  })

  it("delivers comments and alerts, which only the integration sends", async () => {
    const connected = await connectSentry()
    connected.sentry.issues.set(
      "4242",
      fakeIssue({
        activity: [activity({ id: "77", type: "note", user: me, data: { text: "On it" } })]
      })
    )
    const comments = await openSentryStream(connected, "comment.created")
    const alerts = await openSentryStream(connected, "alert.fired")

    await receive(connected, {
      resource: "comment",
      action: "created",
      issueId: "4242",
      commentId: "77"
    })
    await receive(connected, {
      resource: "event_alert",
      action: "triggered",
      issueId: "4242",
      eventId: "abc",
      alert: { rule: "Checkout errors", status: "triggered" }
    })
    await receive(connected, {
      resource: "metric_alert",
      action: "critical",
      alert: { rule: "Too many errors", status: "critical", incidentId: "17" }
    })

    expect(delivered(connected, comments.subscriptionId)).toMatchObject([
      {
        eventId: "comment.created:77",
        data: {
          comment: { id: "77", text: "On it" },
          author: { id: me.id, email: me.email },
          byMe: true
        }
      }
    ])
    expect(delivered(connected, alerts.subscriptionId)).toMatchObject([
      {
        eventId: "alert.fired:issue:abc:Checkout errors",
        data: {
          alert: { kind: "issue", rule: "Checkout errors", status: "triggered" },
          issue: { id: "4242" }
        }
      },
      {
        eventId: "alert.fired:metric:17:critical",
        data: { alert: { kind: "metric", rule: "Too many errors" }, issue: null }
      }
    ])
  })

  it("ignores pings for other organizations, other people's assignments and bad bodies", async () => {
    const connected = await connectSentry()
    connected.sentry.issues.set(
      "4242",
      fakeIssue({
        activity: [activity({ type: "assigned", data: { assignee: sam.id, assigneeType: "user" } })]
      })
    )
    const notStreaming = await receive(connected, {
      resource: "issue",
      action: "created",
      issueId: "4242"
    })
    await openSentryStream(connected, "issue.assigned")

    const outcomes = await Promise.all([
      receive(connected, {
        resource: "issue",
        action: "created",
        organizationId: "999",
        issueId: "4242"
      }),
      receive(connected, { resource: "issue", action: "assigned", issueId: "4242" }),
      receive(connected, { resource: "issue", action: "created", issueId: "404" }),
      receive(connected, { resource: "issue", action: "created", issueId: "4242" }, "other"),
      receive(connected, { resource: "nope" })
    ])

    expect([notStreaming, ...outcomes]).toEqual([
      { accepted: 0, status: 200 },
      { accepted: 0, status: 200 },
      { accepted: 0, status: 200 },
      { accepted: 0, status: 200 },
      { accepted: 0, status: 404 },
      { accepted: 0, status: 400 }
    ])
  })
})

const check = (connected: ConnectedSentry, meta: Record<string, unknown>) =>
  connected.client.request(
    { method: "codevisor/account/check", params: { _meta: meta } },
    anyResult
  )

describe("sentry account check", () => {
  it("names the account by email and routes it by every organization it belongs to", async () => {
    const connected = await connectSentry()

    await expect(check(connected, accountFor())).resolves.toEqual({
      identity: me.email,
      routeKeys: ["101", "202"]
    })
    await expect(check(connected, {})).resolves.toEqual({})
    await expect(check(connected, accountFor("sntryu_revoked"))).rejects.toMatchObject({
      code: -32602
    })
  })
})
