import { accountMeta } from "@codevisor/plugin-kit"
import { anyResult, connectClient, manualClock } from "@codevisor/plugin-kit/test-support"
import type { Notification } from "@modelcontextprotocol/sdk/types.js"
import { describe, expect, it, onTestFinished } from "vitest"

import { gmailStreamLifetimeMs } from "./gmail-push.js"
import { createGmailServer } from "./gmail-server.js"
import {
  accountFor,
  baseTime,
  connectGmail,
  gmailAccessToken,
  gmailIdentity,
  openGmailStream,
  ping,
  pushMeta,
  pushTopic
} from "./gmail-test-support.js"

const incoming = {
  id: "m1",
  threadId: "t1",
  from: "Alice <Alice@Acme.com>",
  to: `${gmailIdentity}, team@acme.com`,
  cc: "carol@acme.com",
  subject: "Launch",
  text: "Ship it Friday",
  internalDate: baseTime + 1_000
}

const streamRequest = (
  connected: Awaited<ReturnType<typeof connectGmail>>,
  meta: Record<string, unknown>
) =>
  connected.client.request(
    {
      method: "events/stream",
      params: { name: "message.received", arguments: {}, cursor: null, _meta: meta }
    },
    anyResult
  )

const eventIds = (notifications: ReadonlyArray<Notification>) =>
  notifications
    .filter((notification) => notification.method === "notifications/events/event")
    .map((notification) => notification.params?.["eventId"])

describe("gmail message.received over push", () => {
  it("declares push delivery, a routed ingress and a typed payload", async () => {
    const { client } = await connectGmail()

    const listed = await client.request({ method: "events/list" }, anyResult)

    expect(client.getServerCapabilities()?.extensions).toMatchObject({
      "dev.codevisor/webhooks": {
        ingress: [{ name: "gmail", title: "Gmail push notifications", route: "gmail" }]
      }
    })
    expect(listed.events).toMatchObject([
      {
        name: "message.received",
        delivery: ["push"],
        payloadSchema: { properties: { from: { type: "object" }, to: { type: "array" } } }
      }
    ])
  })

  it("watches the inbox on the cloud's topic and starts a fresh stream at the mailbox's history", async () => {
    const connected = await connectGmail()
    connected.gmail.add({ id: "old" })

    const stream = await openGmailStream(connected, null)

    expect(stream.active.params).toMatchObject({ cursor: "1001", truncated: false })
    expect(connected.gmail.watches).toEqual([
      { topicName: pushTopic, labelIds: ["INBOX"], labelFilterBehavior: "INCLUDE" }
    ])
    expect(eventIds(connected.inbox.forSubscription(stream.subscriptionId))).toEqual([])
  })

  it("catches up on mail that arrived while it was away, skipping self-sent, archived and deleted mail", async () => {
    const connected = await connectGmail()
    connected.gmail.add(incoming)
    connected.gmail.add({ id: "mine", from: `Me <${gmailIdentity}>` })
    connected.gmail.add({ id: "alias", from: "me+alias@example.com", labels: ["INBOX", "SENT"] })
    connected.gmail.add({ id: "archived", from: "news@example.com", labels: ["CATEGORY_UPDATES"] })
    connected.gmail.add({ id: "deleted", from: "spam@example.com" })
    connected.gmail.remove("deleted")

    const stream = await openGmailStream(connected, "1000")
    const event = await connected.inbox.next("notifications/events/event", stream.subscriptionId)

    expect(stream.active.params).toMatchObject({ cursor: "1005", truncated: false })
    expect(event.params).toMatchObject({
      eventId: "m1",
      name: "message.received",
      timestamp: "2026-10-27T12:00:01.000Z",
      cursor: "1005",
      data: {
        messageId: "m1",
        threadId: "t1",
        from: { email: "alice@acme.com", name: "Alice" },
        to: [gmailIdentity, "team@acme.com"],
        cc: ["carol@acme.com"],
        subject: "Launch",
        snippet: "Ship it Friday",
        labels: ["INBOX", "UNREAD"],
        receivedAt: "2026-10-27T12:00:01.000Z"
      }
    })
    expect(eventIds(connected.inbox.forSubscription(stream.subscriptionId))).toEqual(["m1"])
    const history = connected.gmail.requests.find((request) =>
      request.url.pathname.endsWith("/history")
    )
    expect(Object.fromEntries(history?.url.searchParams ?? [])).toEqual({
      startHistoryId: "1000",
      historyTypes: "messageAdded",
      labelId: "INBOX",
      maxResults: "50"
    })
  })

  it("resyncs from now and marks the gap when the history expired or the cursor isn't a history id", async () => {
    const connected = await connectGmail()
    connected.gmail.add({ id: "m1" })
    connected.gmail.expireHistoryThrough(1000)

    const expired = await openGmailStream(connected, "900")
    const garbage = await openGmailStream(connected, "page-2")

    expect([expired.active.params, garbage.active.params]).toMatchObject([
      { cursor: "1001", truncated: true },
      { cursor: "1001", truncated: true }
    ])
  })

  it("reads history in pages and stops after ten so one stream never stalls on a flood", async () => {
    const connected = await connectGmail()
    for (let index = 0; index < 520; index += 1) connected.gmail.add({ id: `m${index}` })

    const stream = await openGmailStream(connected, "1000")

    const historyCalls = connected.gmail.requests.filter((request) =>
      request.url.pathname.endsWith("/history")
    )
    expect(historyCalls.map((request) => request.url.searchParams.get("startHistoryId"))).toEqual([
      "1000",
      "1050",
      "1100",
      "1150",
      "1200",
      "1250",
      "1300",
      "1350",
      "1400",
      "1450"
    ])
    expect(stream.active.params).toMatchObject({ cursor: "1500", truncated: false })
    for (let index = 520; index < 1_040; index += 1) connected.gmail.add({ id: `m${index}` })
    const flood = await ping(connected, { emailAddress: gmailIdentity, historyId: 2040 })
    const rest = await ping(connected, { emailAddress: gmailIdentity, historyId: 2040 })
    expect([flood, rest]).toEqual([
      { accepted: 500, status: 200 },
      { accepted: 40, status: 200 }
    ])
  })

  it("turns a push notification into events from the stream's cursor, once per message", async () => {
    const connected = await connectGmail()
    const stream = await openGmailStream(connected, null)
    connected.gmail.add(incoming)

    const first = await ping(connected, {
      emailAddress: gmailIdentity.toUpperCase(),
      historyId: 1001
    })
    const repeated = await ping(connected, { emailAddress: gmailIdentity, historyId: "1001" })
    const event = await connected.inbox.next("notifications/events/event", stream.subscriptionId)

    expect([first, repeated]).toEqual([
      { accepted: 1, status: 200 },
      { accepted: 0, status: 200 }
    ])
    expect(event.params).toMatchObject({ eventId: "m1", cursor: "1001" })
  })

  it("ignores notifications for other mailboxes, accounts without a stream, and other ingress", async () => {
    const connected = await connectGmail()
    connected.gmail.add(incoming)

    const noStream = await ping(connected, { emailAddress: gmailIdentity, historyId: 1001 })
    await openGmailStream(connected, null)
    connected.gmail.add({ ...incoming, id: "m2" })
    const otherMailbox = await ping(connected, {
      emailAddress: "someone@example.com",
      historyId: 1002
    })
    const otherIngress = await ping(
      connected,
      { emailAddress: gmailIdentity, historyId: 1002 },
      accountFor(),
      "other"
    )
    const malformed = await ping(connected, { historyId: "x" })
    const notJson = await connected.client.request(
      {
        method: "codevisor/webhook",
        params: {
          ingress: "gmail",
          request: { method: "POST", headers: {}, body: "bm9wZQ==", receivedAt: "" },
          _meta: accountFor()
        }
      },
      anyResult
    )
    const anonymous = await ping(
      connected,
      { emailAddress: gmailIdentity, historyId: 1002 },
      { [accountMeta]: { id: "acct-1", accessToken: gmailAccessToken, fields: {} } }
    )

    expect([noStream, otherMailbox, otherIngress, malformed]).toEqual([
      { accepted: 0, status: 200 },
      { accepted: 0, status: 200 },
      { accepted: 0, status: 404 },
      { accepted: 0, status: 400 }
    ])
    expect(anonymous).toEqual({ accepted: 0, status: 200 })
    expect(notJson).toEqual({ accepted: 0, status: 400 })
  })

  it("reports a Gmail failure as a 502 and picks the missed mail up on the next notification", async () => {
    const connected = await connectGmail()
    const stream = await openGmailStream(connected, null)
    connected.gmail.add(incoming)

    connected.gmail.failNext(500)
    const failed = await ping(connected, { emailAddress: gmailIdentity, historyId: 1001 })
    connected.gmail.add({ ...incoming, id: "m2" })
    const recovered = await ping(connected, { emailAddress: gmailIdentity, historyId: 1002 })

    expect([failed, recovered]).toEqual([
      { accepted: 0, status: 502 },
      { accepted: 2, status: 200 }
    ])
    expect(eventIds(connected.inbox.forSubscription(stream.subscriptionId))).toEqual(["m1", "m2"])
  })

  it("shares one cursor per account between streams and reports it in heartbeats", async () => {
    const connected = await connectGmail()
    const first = await openGmailStream(connected, null)
    const second = await openGmailStream(connected, null)
    connected.gmail.add(incoming)
    await ping(connected, { emailAddress: gmailIdentity, historyId: 1001 })

    connected.clock.advance(15_000)
    const heartbeat = await connected.inbox.next(
      "notifications/events/heartbeat",
      second.subscriptionId
    )

    expect(heartbeat.params).toMatchObject({ cursor: "1001" })
    expect(eventIds(connected.inbox.forSubscription(first.subscriptionId))).toEqual(["m1"])
    expect(eventIds(connected.inbox.forSubscription(second.subscriptionId))).toEqual(["m1"])
  })

  it("gives a second stream on the same account its own backlog", async () => {
    const connected = await connectGmail()
    connected.gmail.add(incoming)

    const first = await openGmailStream(connected, "1000")
    const second = await openGmailStream(connected, "1000")
    await connected.inbox.next("notifications/events/event", second.subscriptionId)

    expect(eventIds(connected.inbox.forSubscription(first.subscriptionId))).toEqual(["m1"])
    expect(eventIds(connected.inbox.forSubscription(second.subscriptionId))).toEqual(["m1"])
  })

  it("ends each stream after six hours so the host reopens it, re-watching with a fresh token", async () => {
    const connected = await connectGmail()
    const stream = await openGmailStream(connected, null)

    connected.clock.advance(gmailStreamLifetimeMs)
    await stream.closed
    const afterClose = await ping(connected, { emailAddress: gmailIdentity, historyId: 1001 })
    const reopened = await openGmailStream(connected, "1000")

    expect(afterClose).toEqual({ accepted: 0, status: 200 })
    expect(reopened.active.params).toMatchObject({ cursor: "1000" })
    expect(connected.gmail.watches).toHaveLength(2)
  })

  it("forgets an account's cursor once its last stream is cancelled", async () => {
    const connected = await connectGmail()
    const cancel = new AbortController()
    const stream = await openGmailStream(connected, null, pushMeta(), cancel.signal)

    cancel.abort()
    await stream.closed.catch(() => undefined)
    connected.gmail.add(incoming)
    const afterCancel = await ping(connected, { emailAddress: gmailIdentity, historyId: 1001 })

    expect(afterCancel).toEqual({ accepted: 0, status: 200 })
  })

  it("refuses streams without push set up, without an account, or with a rejected token", async () => {
    const connected = await connectGmail()

    const withoutPush = streamRequest(connected, accountFor())
    const signedOut = streamRequest(connected, {})
    const rejected = streamRequest(connected, pushMeta("expired"))

    await expect(withoutPush).rejects.toMatchObject({
      code: -32026,
      message: expect.stringContaining("Gmail push isn't set up on this Codevisor Cloud")
    })
    await expect(signedOut).rejects.toMatchObject({ code: -32024 })
    await expect(rejected).rejects.toMatchObject({ code: -32024 })
  })

  it("maps other Gmail failures to upstream errors", async () => {
    const connected = await connectGmail()
    connected.gmail.failNext(503)

    await expect(streamRequest(connected, pushMeta())).rejects.toMatchObject({
      code: -32603,
      data: { status: 503 }
    })
  })

  it("reports an unreachable Gmail as an internal error", async () => {
    const offline = await connectClient(
      createGmailServer({
        fetch: () => Promise.reject(new Error("ENOTFOUND")),
        clock: manualClock()
      })
    )
    onTestFinished(() => offline.client.close())

    await expect(
      offline.client.request(
        {
          method: "events/stream",
          params: { name: "message.received", arguments: {}, cursor: null, _meta: pushMeta() }
        },
        anyResult
      )
    ).rejects.toMatchObject({ code: -32603 })
  })

  it("rejects polling and unknown event types", async () => {
    const { client } = await connectGmail()

    await expect(
      client.request({ method: "events/poll", params: { name: "message.received" } }, anyResult)
    ).rejects.toMatchObject({ code: -32026, data: { value: "poll" } })
    await expect(
      client.request({ method: "events/stream", params: { name: "message.sent" } }, anyResult)
    ).rejects.toMatchObject({ code: -32023 })
  })

  it("stops the Gmail watch when an account is removed, even if Gmail refuses", async () => {
    const connected = await connectGmail()
    const remove = (meta: Record<string, unknown>) =>
      connected.client.request(
        { method: "codevisor/account/remove", params: { _meta: meta } },
        anyResult
      )

    const removed = await remove(accountFor())
    connected.gmail.failNext(500)
    const refused = await remove(accountFor())

    expect([removed, refused]).toEqual([{}, {}])
    expect(connected.gmail.stops).toBe(1)
    await expect(remove({})).rejects.toMatchObject({ code: -32024 })
  })
})
