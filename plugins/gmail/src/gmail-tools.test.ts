import { accountMeta } from "@codevisor/plugin-kit"
import {
  type ConnectedClient,
  connectClient,
  manualClock,
  toolText
} from "@codevisor/plugin-kit/test-support"
import { afterEach, describe, expect, it } from "vitest"

import { createGmailServer } from "./gmail-server.js"
import { type FakeGmail, fakeGmail, gmailAccessToken, gmailIdentity } from "./gmail-test-support.js"

const connections: Array<ConnectedClient> = []

const account = (accessToken = gmailAccessToken) => ({
  [accountMeta]: {
    id: "acct-1",
    label: "Work",
    identity: gmailIdentity,
    accessToken,
    fields: { clientId: "client" }
  }
})

const connect = async (gmail: FakeGmail = fakeGmail()) => {
  const connected = await connectClient(
    createGmailServer({ fetch: gmail.fetch, clock: manualClock() })
  )
  connections.push(connected)
  return { ...connected, gmail }
}

const call = (
  connected: ConnectedClient,
  name: string,
  args: Record<string, unknown>,
  meta: Record<string, unknown> = account()
) => connected.client.callTool({ name, arguments: args, _meta: meta })

const original = {
  id: "m1",
  threadId: "t1",
  from: "Alice <alice@acme.com>",
  to: gmailIdentity,
  subject: "Launch plan",
  messageIdHeader: "<m1@acme.com>",
  references: "<m0@acme.com>",
  text: "Can you confirm Friday?"
}

describe("gmail tools", () => {
  afterEach(async () => {
    await Promise.all(connections.splice(0).map((connected) => connected.client.close()))
  })

  it("annotates read tools as read-only and send as open-world", async () => {
    const { client } = await connect()

    const { tools } = await client.listTools()
    const annotations = Object.fromEntries(tools.map((tool) => [tool.name, tool.annotations]))

    expect(Object.keys(annotations)).toEqual([
      "search",
      "read_message",
      "read_thread",
      "create_draft",
      "send",
      "modify_labels"
    ])
    expect([
      annotations["search"],
      annotations["read_message"],
      annotations["read_thread"]
    ]).toEqual(Array.from({ length: 3 }, () => ({ readOnlyHint: true, openWorldHint: false })))
    expect(annotations["send"]).toMatchObject({ readOnlyHint: false, openWorldHint: true })
  })

  it("searches with Gmail query syntax and returns message metadata", async () => {
    const connected = await connect()
    connected.gmail.add(original)
    connected.gmail.add({
      id: "m2",
      from: "bob@example.com",
      subject: "Lunch",
      cc: "carol@example.com"
    })

    const result = await call(connected, "search", { query: "is:unread", maxResults: 5 })

    expect(result.structuredContent).toMatchObject({
      messages: [
        {
          id: "m2",
          from: { email: "bob@example.com" },
          cc: ["carol@example.com"],
          subject: "Lunch"
        },
        {
          id: "m1",
          from: { email: "alice@acme.com", name: "Alice" },
          to: [gmailIdentity],
          subject: "Launch plan"
        }
      ]
    })
    const list = connected.gmail.requests[0]?.url
    expect(list?.pathname).toBe("/gmail/v1/users/me/messages")
    expect(Object.fromEntries(list?.searchParams ?? [])).toEqual({
      q: "is:unread",
      maxResults: "5"
    })
    expect(connected.gmail.requests[1]?.url.searchParams.getAll("metadataHeaders")).toContain(
      "Message-ID"
    )
  })

  it("reads a message and a thread with decoded plain-text bodies", async () => {
    const connected = await connect()
    connected.gmail.add(original)
    connected.gmail.add({
      id: "m2",
      threadId: "t1",
      from: "bob@example.com",
      html: "<p>Yes &amp; thanks</p>"
    })

    const message = await call(connected, "read_message", { messageId: "m1" })
    const thread = await call(connected, "read_thread", { threadId: "t1" })

    expect(message.structuredContent).toMatchObject({
      message: {
        id: "m1",
        messageIdHeader: "<m1@acme.com>",
        body: "Can you confirm Friday?",
        labels: ["INBOX", "UNREAD"]
      }
    })
    expect(thread.structuredContent).toMatchObject({
      threadId: "t1",
      messages: [{ id: "m1" }, { id: "m2", body: "Yes & thanks" }]
    })
    expect(JSON.parse(toolText(thread))).toEqual(thread.structuredContent)
  })

  it("drafts a reply in the thread with In-Reply-To, References and the sender as recipient", async () => {
    const connected = await connect()
    connected.gmail.add(original)

    const result = await call(connected, "create_draft", {
      body: "Friday works.",
      inReplyToMessageId: "m1"
    })

    expect(result.structuredContent).toEqual({
      draftId: "r-1",
      messageId: "draft-1",
      threadId: "t1"
    })
    expect(connected.gmail.outbox[0]?.threadId).toBe("t1")
    expect(connected.gmail.outbox[0]?.message).toBe(
      [
        "To: Alice <alice@acme.com>",
        "Subject: Re: Launch plan",
        "In-Reply-To: <m1@acme.com>",
        "References: <m0@acme.com> <m1@acme.com>",
        "MIME-Version: 1.0",
        'Content-Type: text/plain; charset="UTF-8"',
        "Content-Transfer-Encoding: base64",
        "",
        Buffer.from("Friday works.").toString("base64"),
        ""
      ].join("\r\n")
    )
  })

  it("keeps an existing Re: prefix and omits threading headers the original lacks", async () => {
    const connected = await connect()
    connected.gmail.add({ id: "m3", from: "dana@example.com", subject: "RE: Budget" })

    await call(connected, "create_draft", { body: "ok", inReplyToMessageId: "m3" })
    await call(connected, "create_draft", { body: "fresh note" })

    expect(connected.gmail.outbox[0]?.message).toContain("Subject: RE: Budget\r\nMIME-Version")
    expect(connected.gmail.outbox[0]?.message).not.toContain("In-Reply-To")
    expect(connected.gmail.outbox[1]?.message.startsWith("Subject: \r\nMIME-Version")).toBe(true)
    expect(connected.gmail.outbox[1]?.threadId).toBeUndefined()
  })

  it("sends with cc, encodes non-ASCII subjects, wraps long bodies and strips header line breaks", async () => {
    const connected = await connect()
    const body = "é".repeat(60)

    const result = await call(connected, "send", {
      to: "bob@example.com\r\nBcc: attacker@evil.test",
      cc: "carol@example.com",
      subject: "Résumé",
      body,
      threadId: "t9"
    })

    const message = String(connected.gmail.outbox[0]?.message)
    expect(result.structuredContent).toEqual({
      messageId: "sent-1",
      threadId: "t9",
      labels: ["SENT"]
    })
    expect(message).toContain(
      "To: bob@example.com Bcc: attacker@evil.test\r\nCc: carol@example.com\r\n"
    )
    expect(message).not.toContain("\r\nBcc:")
    expect(message).toContain(`Subject: =?UTF-8?B?${Buffer.from("Résumé").toString("base64")}?=`)
    const encodedBody = message.split("\r\n\r\n")[1] ?? ""
    expect(encodedBody.split("\r\n").map((line) => line.length)).toEqual([76, 76, 8, 0])
    expect(Buffer.from(encodedBody.replaceAll("\r\n", ""), "base64").toString("utf8")).toBe(body)
  })

  it("adds and removes labels", async () => {
    const connected = await connect()
    connected.gmail.add(original)

    const result = await call(connected, "modify_labels", {
      messageId: "m1",
      add: ["STARRED"],
      remove: ["UNREAD"]
    })

    expect(result.structuredContent).toEqual({ messageId: "m1", labels: ["INBOX", "STARRED"] })
    expect(connected.gmail.labelsOf("m1")).toEqual(["INBOX", "STARRED"])
  })

  it("reports bad arguments, Gmail errors and network failures as tool errors", async () => {
    const connected = await connect()

    const noLabels = await call(connected, "modify_labels", { messageId: "m1" })
    const missing = await call(connected, "read_message", { messageId: "gone" })
    const missingLabels = await call(connected, "modify_labels", {
      messageId: "gone",
      add: ["STARRED"]
    })
    connected.gmail.failNext(500)
    const failing = await call(connected, "read_thread", { threadId: "t1" })
    const unknown = await call(connected, "archive_everything", {})
    const noArguments = await connected.client.callTool({ name: "search", _meta: account() })

    expect(toolText(noLabels)).toContain("Give at least one label id to add or remove.")
    expect(missing).toMatchObject({
      isError: true,
      content: [{ text: expect.stringContaining("Gmail returned 404") }]
    })
    expect(missingLabels.isError).toBe(true)
    expect(toolText(failing)).toContain("Gmail returned 500")
    expect(toolText(unknown)).toBe("Unknown tool: archive_everything")
    expect(toolText(noArguments)).toContain("query")
  })

  it("reports unreachable Gmail and missing accounts without calling the API", async () => {
    const unreachable = await connectClient(
      createGmailServer({
        fetch: () => Promise.reject(new Error("ENOTFOUND")),
        clock: manualClock()
      })
    )
    connections.push(unreachable)
    const connected = await connect()

    const offline = await call(unreachable, "search", { query: "x" })
    const signedOut = await call(connected, "search", { query: "x" }, {})
    const noToken = await call(
      connected,
      "search",
      { query: "x" },
      { [accountMeta]: { id: "acct-1", identity: gmailIdentity, fields: {} } }
    )
    const emptyToken = await call(connected, "search", { query: "x" }, account(""))

    expect(toolText(offline)).toBe("Gmail request failed: Error: ENOTFOUND")
    expect([signedOut, noToken, emptyToken].map(toolText)).toEqual(
      Array.from(
        { length: 3 },
        () => "A signed-in Google account is required. Connect one in Settings › Plugins › Gmail."
      )
    )
    expect(connected.gmail.requests).toEqual([])
  })
})
