import { accountMeta } from "@codevisor/plugin-kit"
import { connectClient, manualClock, toolText } from "@codevisor/plugin-kit/test-support"
import { describe, expect, it } from "vitest"

import { createGmailServer } from "./gmail-server.js"
import {
  accountFor,
  callTool,
  connectGmail,
  fakeLabels,
  gmailIdentity
} from "./gmail-test-support.js"

const alice = {
  id: "m1",
  threadId: "t1",
  from: "Alice <alice@acme.com>",
  to: gmailIdentity,
  subject: "Launch plan",
  text: "Can you confirm Friday? It&#39;s close"
}

describe("gmail read tools", () => {
  it("annotates reads as read-only, sends as open-world, and requires confirm to send", async () => {
    const { client } = await connectGmail()

    const { tools } = await client.listTools()
    const byName = Object.fromEntries(tools.map((tool) => [tool.name, tool]))

    expect(tools.filter((tool) => tool.annotations?.readOnlyHint).map((tool) => tool.name)).toEqual(
      ["search_messages", "search_threads", "read_message", "read_thread", "list_labels"]
    )
    expect(
      tools.filter((tool) => tool.annotations?.openWorldHint).map((tool) => tool.name)
    ).toEqual(["send", "reply"])
    expect(byName["send"]?.inputSchema.required).toEqual(["confirm"])
    expect(byName["reply"]?.inputSchema.required).toContain("confirm")
  })

  it("searches messages with Gmail syntax and returns compact one-line JSON", async () => {
    const connected = await connectGmail()
    connected.gmail.add(alice)
    connected.gmail.add({ id: "m2", from: "bob@example.com", subject: "Lunch", cc: "c@x.io" })

    const result = await callTool(connected, "search_messages", { query: "is:unread" })

    expect(result.structuredContent).toEqual({
      messages: [
        {
          id: "m2",
          threadId: "m2",
          date: "2026-10-27T12:00:00.000Z",
          from: "bob@example.com",
          to: "",
          cc: "c@x.io",
          subject: "Lunch",
          snippet: "",
          labels: ["INBOX", "UNREAD"]
        },
        expect.objectContaining({
          id: "m1",
          from: "Alice <alice@acme.com>",
          snippet: "Can you confirm Friday? It's close"
        })
      ]
    })
    expect(toolText(result)).toBe(JSON.stringify(result.structuredContent))
    const list = connected.gmail.requests[0]?.url
    expect(list?.pathname).toBe("/gmail/v1/users/me/messages")
    expect(Object.fromEntries(list?.searchParams ?? [])).toEqual({
      q: "is:unread",
      maxResults: "10"
    })
    expect(connected.gmail.requests[1]?.url.searchParams.getAll("metadataHeaders")).toContain(
      "Reply-To"
    )
  })

  it("pages through search results with nextPageToken", async () => {
    const connected = await connectGmail()
    for (const id of ["m1", "m2", "m3"]) connected.gmail.add({ ...alice, id, threadId: id })

    const first = await callTool(connected, "search_messages", { query: "", maxResults: 2 })
    const second = await callTool(connected, "search_messages", {
      query: "",
      maxResults: 2,
      pageToken: "2"
    })

    expect(first.structuredContent).toMatchObject({
      messages: [{ id: "m3" }, { id: "m2" }],
      nextPageToken: "2"
    })
    expect(second.structuredContent).toEqual({ messages: [expect.objectContaining({ id: "m1" })] })
  })

  it("summarizes threads with their subject, senders, size and latest activity", async () => {
    const connected = await connectGmail()
    connected.gmail.add(alice)
    connected.gmail.add({
      id: "m2",
      threadId: "t1",
      from: "bob@example.com",
      text: "Friday works",
      labels: ["INBOX"],
      internalDate: Date.parse("2026-10-27T13:00:00.000Z")
    })
    connected.gmail.add({ id: "m3", from: "Alice <alice@acme.com>", subject: "Other" })

    const result = await callTool(connected, "search_threads", { query: "in:inbox" })

    expect(result.structuredContent).toEqual({
      threads: [
        expect.objectContaining({ id: "m3", subject: "Other", from: ["Alice"], messages: 1 }),
        {
          id: "t1",
          subject: "Launch plan",
          from: ["Alice", "bob@example.com"],
          messages: 2,
          date: "2026-10-27T13:00:00.000Z",
          snippet: "Friday works",
          labels: ["INBOX", "UNREAD"]
        }
      ]
    })
  })

  it("reads a message with its whole body, reply-to and attachment list", async () => {
    const connected = await connectGmail()
    connected.gmail.add({
      ...alice,
      replyTo: "team@acme.com",
      text: "Agenda attached.\r\n\r\n\r\n\r\nOn Mon, Bob wrote:\r\n> earlier",
      attachments: [{ filename: "agenda.pdf", mimeType: "application/pdf", size: 2048 }]
    })

    const result = await callTool(connected, "read_message", { messageId: "m1" })

    expect(result.structuredContent).toEqual({
      id: "m1",
      threadId: "t1",
      date: "2026-10-27T12:00:00.000Z",
      from: "Alice <alice@acme.com>",
      to: gmailIdentity,
      subject: "Launch plan",
      labels: ["INBOX", "UNREAD"],
      replyTo: "team@acme.com",
      body: "Agenda attached.\n\nOn Mon, Bob wrote:\n> earlier",
      attachments: [{ filename: "agenda.pdf", mimeType: "application/pdf", size: 2048 }]
    })
    expect(connected.gmail.requests[0]?.url.searchParams.get("format")).toBe("full")
  })

  it("reads a thread oldest first with quoted history trimmed and HTML turned into text", async () => {
    const connected = await connectGmail()
    connected.gmail.add(alice)
    connected.gmail.add({
      id: "m2",
      threadId: "t1",
      from: "bob@example.com",
      text: "Yes, Friday.\n\nOn Tue, Oct 27, 2026 at 9:00 AM Alice <\nalice@acme.com> wrote:\n> Can you confirm Friday?\n>"
    })
    connected.gmail.add({
      id: "m3",
      threadId: "t1",
      from: "carol@example.com",
      html: "<style>p{}</style><p>Thanks &amp; see&nbsp;you</p><div>&#x1F44D; &#8212; &lt;done&gt;</div>"
    })

    const result = await callTool(connected, "read_thread", { threadId: "t1" })

    expect(result.structuredContent).toMatchObject({
      threadId: "t1",
      messages: [
        { id: "m1", body: "Can you confirm Friday? It&#39;s close" },
        { id: "m2", body: "Yes, Friday.\n[quoted history hidden]" },
        { id: "m3", body: "Thanks & see you\n👍 — <done>" }
      ]
    })
  })

  it("lists labels with ids, names and types", async () => {
    const connected = await connectGmail()

    const result = await callTool(connected, "list_labels", {})

    expect(result.structuredContent).toEqual({ labels: fakeLabels })
  })

  it("reports bad arguments, Gmail errors and unknown tools as tool errors", async () => {
    const connected = await connectGmail()

    const missing = await callTool(connected, "read_message", { messageId: "gone" })
    connected.gmail.failNext(500)
    const failing = await callTool(connected, "read_thread", { threadId: "t1" })
    connected.gmail.failNext(503, "upstream unavailable")
    const plain = await callTool(connected, "list_labels", {})
    connected.gmail.failNext(502, "")
    const empty = await callTool(connected, "list_labels", {})
    const unknown = await callTool(connected, "delete_everything", {})
    const noArguments = await connected.client.callTool({
      name: "search_messages",
      _meta: accountFor()
    })

    expect(missing).toMatchObject({
      isError: true,
      content: [{ text: "Gmail returned 404: Not Found" }]
    })
    expect(toolText(failing)).toBe("Gmail returned 500: Backend Error")
    expect(toolText(plain)).toBe("Gmail returned 503: upstream unavailable")
    expect(toolText(empty)).toBe("Gmail returned 502")
    expect(toolText(unknown)).toBe("Unknown tool: delete_everything")
    expect(toolText(noArguments)).toContain("query")
  })

  it("asks for a fresh sign-in when Gmail rejects the token, and needs an account first", async () => {
    const connected = await connectGmail()

    const rejected = await callTool(connected, "list_labels", {}, accountFor("expired"))
    const signedOut = await callTool(connected, "list_labels", {}, {})
    const noToken = await callTool(
      connected,
      "list_labels",
      {},
      { [accountMeta]: { id: "acct-1", identity: gmailIdentity, fields: {} } }
    )
    const emptyToken = await callTool(connected, "list_labels", {}, accountFor(""))

    expect(toolText(rejected)).toBe(
      "Gmail rejected the sign-in. Sign in again in Settings › Plugins › Gmail."
    )
    expect([signedOut, noToken, emptyToken].map(toolText)).toEqual(
      Array.from(
        { length: 3 },
        () => "A signed-in Google account is required. Sign in from Settings › Plugins › Gmail."
      )
    )
    expect(connected.gmail.requests).toHaveLength(1)
  })

  it("reports an unreachable Gmail", async () => {
    const offline = await connectClient(
      createGmailServer({
        fetch: () => Promise.reject(new Error("ENOTFOUND")),
        clock: manualClock()
      })
    )

    const result = await callTool(offline, "list_labels", {})

    expect(toolText(result)).toBe("Gmail request failed: Error: ENOTFOUND")
    await offline.client.close()
  })
})
