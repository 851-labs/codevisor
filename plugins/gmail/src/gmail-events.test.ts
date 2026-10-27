import { accountMeta } from "@codevisor/plugin-kit"
import {
  anyResult,
  type ConnectedClient,
  connectClient,
  manualClock
} from "@codevisor/plugin-kit/test-support"
import { afterEach, describe, expect, it } from "vitest"

import { createGmailServer } from "./gmail-server.js"
import {
  baseTime,
  type FakeGmail,
  fakeGmail,
  gmailAccessToken,
  gmailIdentity
} from "./gmail-test-support.js"

const connections: Array<ConnectedClient> = []

const meta = (overrides: Record<string, unknown> = {}) => ({
  [accountMeta]: {
    id: "acct-1",
    identity: gmailIdentity,
    accessToken: gmailAccessToken,
    fields: {},
    ...overrides
  }
})

const connect = async (gmail: FakeGmail = fakeGmail()) => {
  const clock = manualClock(baseTime + 60_000)
  const connected = await connectClient(createGmailServer({ fetch: gmail.fetch, clock }))
  connections.push(connected)
  return { ...connected, gmail }
}

const poll = (
  connected: ConnectedClient,
  params: Record<string, unknown>,
  account: Record<string, unknown> = meta()
) =>
  connected.client.request(
    {
      method: "events/poll",
      params: { name: "message.received", arguments: {}, ...params, _meta: account }
    },
    anyResult
  )

const eventIds = (result: Record<string, unknown>): Array<unknown> =>
  (Array.isArray(result["events"]) ? result["events"] : []).map(
    (event: { eventId: unknown }) => event.eventId
  )

describe("gmail message.received events", () => {
  afterEach(async () => {
    await Promise.all(connections.splice(0).map((connected) => connected.client.close()))
  })

  it("declares poll delivery and a typed payload for CEL filters", async () => {
    const { client } = await connect()

    const listed = await client.request({ method: "events/list" }, anyResult)

    expect(listed.events).toMatchObject([
      {
        name: "message.received",
        delivery: ["poll"],
        payloadSchema: {
          properties: {
            from: {
              type: "object",
              properties: { email: { type: "string" }, name: { type: "string" } }
            },
            to: { type: "array", items: { type: "string" } },
            receivedAt: { type: "string", format: "date-time" }
          }
        }
      }
    ])
  })

  it("starts a null cursor at the mailbox's current historyId without events", async () => {
    const connected = await connect()
    connected.gmail.add({ id: "old" })

    const result = await poll(connected, { cursor: null })

    expect(result).toEqual({
      resultType: "complete",
      events: [],
      cursor: "1001",
      truncated: false,
      hasMore: false,
      nextPollMs: 30_000
    })
  })

  it("returns new inbox mail since the cursor, skipping self-sent, archived and deleted messages", async () => {
    const connected = await connect()
    const { cursor } = await poll(connected, { cursor: null })
    connected.gmail.add({
      id: "m1",
      threadId: "t1",
      from: "Alice <Alice@Acme.com>",
      to: `${gmailIdentity}, team@acme.com`,
      cc: "carol@acme.com",
      subject: "Launch",
      text: "Ship it Friday",
      internalDate: baseTime + 1_000
    })
    connected.gmail.add({ id: "mine", from: `Me <${gmailIdentity}>` })
    connected.gmail.add({ id: "alias", from: "me+alias@example.com", labels: ["INBOX", "SENT"] })
    connected.gmail.add({ id: "archived", from: "news@example.com", labels: ["CATEGORY_UPDATES"] })
    connected.gmail.add({ id: "deleted", from: "spam@example.com" })
    connected.gmail.remove("deleted")
    await connected.client.callTool({
      name: "send",
      arguments: { to: "alice@acme.com", subject: "Re: Launch", body: "Yes" },
      _meta: meta()
    })

    const result = await poll(connected, { cursor })

    expect(result).toMatchObject({
      cursor: "1006",
      truncated: false,
      hasMore: false,
      nextPollMs: 30_000
    })
    expect(result["events"]).toEqual([
      {
        eventId: "m1",
        name: "message.received",
        timestamp: "2026-10-27T12:00:01.000Z",
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
      }
    ])
    const history = connected.gmail.requests.find((request) =>
      request.url.pathname.endsWith("/history")
    )
    expect(Object.fromEntries(history?.url.searchParams ?? [])).toEqual({
      startHistoryId: "1000",
      historyTypes: "messageAdded",
      labelId: "INBOX",
      maxResults: "25"
    })
  })

  it("delivers mail from the account's own address when the account has no identity", async () => {
    const connected = await connect()
    const { cursor } = await poll(connected, { cursor: null })
    connected.gmail.add({ id: "note-to-self", from: gmailIdentity })

    const result = await poll(connected, { cursor }, meta({ identity: undefined }))

    expect(eventIds(result)).toEqual(["note-to-self"])
  })

  it("pages with an intermediate history cursor and hasMore", async () => {
    const connected = await connect()
    const { cursor } = await poll(connected, { cursor: null })
    for (const id of ["a", "b", "c"]) connected.gmail.add({ id })

    const first = await poll(connected, { cursor, maxEvents: 2 })
    const second = await poll(connected, { cursor: first["cursor"], maxEvents: 2 })

    expect(first).toMatchObject({ cursor: "1002", hasMore: true })
    expect(eventIds(first)).toEqual(["a", "b"])
    expect(second).toMatchObject({ cursor: "1003", hasMore: false })
    expect(eventIds(second)).toEqual(["c"])
  })

  it("caps maxEvents at 50 history records per poll", async () => {
    const connected = await connect()

    await poll(connected, { cursor: "1000", maxEvents: 500 })

    expect(connected.gmail.requests[0]?.url.searchParams.get("maxResults")).toBe("50")
  })

  it("reports truncated with a fresh cursor when history expired or the cursor is not a historyId", async () => {
    const connected = await connect()
    connected.gmail.add({ id: "m1" })
    connected.gmail.expireHistoryThrough(1000)

    const expired = await poll(connected, { cursor: "900" })
    const garbage = await poll(connected, { cursor: "page-2" })

    expect(expired).toMatchObject({ events: [], cursor: "1001", truncated: true, hasMore: false })
    expect(garbage).toMatchObject({ events: [], cursor: "1001", truncated: true })
  })

  it("drops messages older than maxAgeMs and marks the gap", async () => {
    const connected = await connect()
    const { cursor } = await poll(connected, { cursor: null })
    connected.gmail.add({ id: "stale", internalDate: baseTime - 3_600_000 })
    connected.gmail.add({ id: "fresh", internalDate: baseTime + 30_000 })

    const result = await poll(connected, { cursor, maxAgeMs: 300_000 })

    expect(eventIds(result)).toEqual(["fresh"])
    expect(result["truncated"]).toBe(true)
  })

  it("maps Gmail auth failures to Forbidden and other failures to upstream errors", async () => {
    const connected = await connect()

    await expect(
      poll(connected, { cursor: null }, meta({ accessToken: "expired" }))
    ).rejects.toMatchObject({
      code: -32024,
      data: { reason: "Gmail rejected the access token." }
    })
    connected.gmail.failNext(503)
    await expect(poll(connected, { cursor: "1000" })).rejects.toMatchObject({
      code: -32603,
      data: { status: 503 }
    })
    await expect(poll(connected, { cursor: null }, {})).rejects.toMatchObject({ code: -32024 })
  })

  it("surfaces network failures as internal errors", async () => {
    const connected = await connectClient(
      createGmailServer({
        fetch: () => Promise.reject(new Error("ENOTFOUND")),
        clock: manualClock()
      })
    )
    connections.push(connected)

    await expect(poll(connected, { cursor: null })).rejects.toMatchObject({ code: -32603 })
  })

  it("rejects push delivery and unknown event types", async () => {
    const { client } = await connect()

    await expect(
      client.request({ method: "events/stream", params: { name: "message.received" } }, anyResult)
    ).rejects.toMatchObject({ code: -32026, data: { value: "push" } })
    await expect(
      client.request({ method: "events/poll", params: { name: "message.sent" } }, anyResult)
    ).rejects.toMatchObject({ code: -32023 })
  })

  it("serves the gmail-replies skill", async () => {
    const { client } = await connect()

    const listed = await client.request({ method: "skills/list" }, anyResult)
    const skill = await client.readResource({ uri: "skill://gmail-replies/SKILL.md" })

    expect(client.getServerCapabilities()?.extensions).toEqual({
      "io.modelcontextprotocol/events": { listChanged: false },
      "io.modelcontextprotocol/skills": {}
    })
    expect(listed.skills).toMatchObject([
      { uri: "skill://gmail-replies/SKILL.md", frontmatter: { name: "gmail-replies" } }
    ])
    expect(skill.contents[0]).toMatchObject({
      mimeType: "text/markdown",
      text: expect.stringContaining("inReplyToMessageId")
    })
  })
})
