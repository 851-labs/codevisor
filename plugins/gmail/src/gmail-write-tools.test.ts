import { toolText } from "@codevisor/plugin-kit/test-support"
import { describe, expect, it } from "vitest"

import { bodyOf, callTool, connectGmail, gmailIdentity } from "./gmail-test-support.js"

const original = {
  id: "m1",
  threadId: "t1",
  from: "Alice <alice@acme.com>",
  to: `${gmailIdentity}, Bob <bob@acme.com>`,
  cc: "Carol <carol@acme.com>, me@EXAMPLE.com",
  subject: "Launch plan",
  messageIdHeader: "<m1@acme.com>",
  references: "<m0@acme.com>",
  text: "Can you confirm Friday?"
}

const headerLines = (message: string): Array<string> =>
  (message.split("\r\n\r\n")[0] ?? "").split("\r\n")

const mimeLines = [
  "MIME-Version: 1.0",
  'Content-Type: text/plain; charset="UTF-8"',
  "Content-Transfer-Encoding: base64"
]

describe("gmail drafts", () => {
  it("drafts a reply in the thread to the sender, with threading headers", async () => {
    const connected = await connectGmail()
    connected.gmail.add(original)

    const result = await callTool(connected, "create_draft", {
      body: "Friday works.",
      inReplyToMessageId: "m1"
    })

    expect(result.structuredContent).toEqual({
      draftId: "r-1",
      messageId: "draft-1",
      threadId: "t1",
      to: "Alice <alice@acme.com>",
      subject: "Re: Launch plan"
    })
    const draft = connected.gmail.outbox[0]
    expect(draft?.threadId).toBe("t1")
    expect(headerLines(String(draft?.message))).toEqual([
      "To: Alice <alice@acme.com>",
      "Subject: Re: Launch plan",
      "In-Reply-To: <m1@acme.com>",
      "References: <m0@acme.com> <m1@acme.com>",
      ...mimeLines
    ])
    expect(bodyOf(String(draft?.message))).toBe("Friday works.")
  })

  it("copies everyone but me on reply-all and prefers Reply-To over From", async () => {
    const connected = await connectGmail()
    connected.gmail.add({ ...original, replyTo: "Launch Team <launch@acme.com>" })

    const result = await callTool(connected, "create_draft", {
      body: "Friday works.",
      inReplyToMessageId: "m1",
      replyAll: true
    })

    expect(result.structuredContent).toMatchObject({
      to: "Launch Team <launch@acme.com>",
      cc: "Bob <bob@acme.com>, Carol <carol@acme.com>"
    })
  })

  it("answers my own message by writing to its recipients again", async () => {
    const connected = await connectGmail()
    connected.gmail.add({
      id: "m1",
      threadId: "t1",
      from: `Me <${gmailIdentity}>`,
      to: "Bob <bob@acme.com>",
      subject: "RE: Budget"
    })

    const result = await callTool(connected, "create_draft", {
      body: "Following up.",
      inReplyToMessageId: "m1",
      replyAll: true
    })

    expect(result.structuredContent).toMatchObject({
      to: "Bob <bob@acme.com>",
      subject: "RE: Budget"
    })
    expect(String(connected.gmail.outbox[0]?.message)).not.toContain("In-Reply-To")
  })

  it("drafts a new message, encoding non-ASCII names and subjects and dropping header injection", async () => {
    const connected = await connectGmail()

    const result = await callTool(connected, "create_draft", {
      to: 'Zoë <zoe@example.com>, "Doe, Jane" <jane@example.com>',
      bcc: "audit@example.com\r\nX-Evil: 1",
      subject: "Résumé\r\nBcc: attacker@evil.test",
      body: "é".repeat(60)
    })

    const message = String(connected.gmail.outbox[0]?.message)
    expect(result.structuredContent).toMatchObject({ draftId: "r-1", threadId: "draft-1" })
    expect(headerLines(message).slice(0, 3)).toEqual([
      `To: =?UTF-8?B?${Buffer.from("Zoë").toString("base64")}?= <zoe@example.com>, "Doe, Jane" <jane@example.com>`,
      expect.stringMatching(/^Bcc: audit@example\.com\b/),
      `Subject: =?UTF-8?B?${Buffer.from("Résumé Bcc: attacker@evil.test").toString("base64")}?=`
    ])
    expect(headerLines(message).filter((line) => /^x-evil:/i.test(line))).toEqual([])
    expect(connected.gmail.outbox[0]?.threadId).toBeUndefined()
    const encodedBody = message.split("\r\n\r\n")[1] ?? ""
    expect(encodedBody.split("\r\n").map((line) => line.length)).toEqual([76, 76, 8, 0])
    expect(bodyOf(message)).toBe("é".repeat(60))
  })

  it("drafts a bare note with only a body", async () => {
    const connected = await connectGmail()

    const result = await callTool(connected, "create_draft", { body: "note to self" })

    expect(result.structuredContent).toEqual({
      draftId: "r-1",
      messageId: "draft-1",
      threadId: "draft-1"
    })
    expect(headerLines(String(connected.gmail.outbox[0]?.message))).toEqual([
      "Subject: ",
      ...mimeLines
    ])
  })

  it("updates a draft, keeping the fields and threading it doesn't change", async () => {
    const connected = await connectGmail()
    connected.gmail.addDraft("r-7", {
      id: "d7",
      threadId: "t1",
      to: "Alice <alice@acme.com>",
      bcc: "audit@example.com",
      subject: "Re: Launch plan",
      inReplyTo: "<m1@acme.com>",
      references: "<m1@acme.com>",
      text: "Friday works."
    })

    const subjectOnly = await callTool(connected, "update_draft", {
      draftId: "r-7",
      subject: "Re: Launch plan (Friday)"
    })
    await callTool(connected, "update_draft", { draftId: "r-7", body: "Thursday?" })

    expect(subjectOnly.structuredContent).toMatchObject({ draftId: "r-7", threadId: "t1" })
    expect(connected.gmail.requests[1]).toMatchObject({ method: "PUT", body: { id: "r-7" } })
    const [renamed, rewritten] = connected.gmail.outbox.map((entry) => entry.message)
    expect(headerLines(String(renamed))).toEqual([
      "To: Alice <alice@acme.com>",
      "Bcc: audit@example.com",
      "Subject: Re: Launch plan (Friday)",
      "In-Reply-To: <m1@acme.com>",
      "References: <m1@acme.com>",
      ...mimeLines
    ])
    expect(bodyOf(String(renamed))).toBe("Friday works.")
    expect(bodyOf(String(rewritten))).toBe("Thursday?")
  })
})

describe("gmail sending", () => {
  it("refuses to send or reply without confirm: true and sends nothing", async () => {
    const connected = await connectGmail()
    connected.gmail.add(original)

    const send = await callTool(connected, "send", {
      to: "bob@acme.com",
      subject: "Hi",
      body: "Hi"
    })
    const reply = await callTool(connected, "reply", {
      messageId: "m1",
      body: "Yes",
      confirm: "yes"
    })

    expect(toolText(send)).toBe(
      "send requires confirm: true. Show the user the exact recipients, subject and body, and get their explicit approval first."
    )
    expect(toolText(reply)).toMatch(/^reply requires confirm: true/)
    expect(connected.gmail.requests).toEqual([])
  })

  it("sends a new message once confirmed", async () => {
    const connected = await connectGmail()

    const result = await callTool(connected, "send", {
      to: "bob@acme.com",
      cc: "carol@acme.com",
      subject: "Hi",
      body: "Hello",
      confirm: true
    })

    expect(result.structuredContent).toEqual({ messageId: "sent-1", threadId: "sent-1" })
    expect(headerLines(String(connected.gmail.outbox[0]?.message)).slice(0, 3)).toEqual([
      "To: bob@acme.com",
      "Cc: carol@acme.com",
      "Subject: Hi"
    ])
  })

  it("sends an approved draft by id", async () => {
    const connected = await connectGmail()
    connected.gmail.addDraft("r-3", { id: "d3", threadId: "t1", to: "alice@acme.com", text: "ok" })

    const result = await callTool(connected, "send", { draftId: "r-3", confirm: true })

    expect(result.structuredContent).toEqual({ messageId: "sent-1", threadId: "t1" })
    expect(connected.gmail.requests[0]).toMatchObject({ method: "POST", body: { id: "r-3" } })
  })

  it("replies in the thread once confirmed, with extra cc", async () => {
    const connected = await connectGmail()
    connected.gmail.add(original)

    const result = await callTool(connected, "reply", {
      messageId: "m1",
      body: "Confirmed.",
      cc: "dana@acme.com",
      confirm: true
    })

    expect(result.structuredContent).toEqual({
      messageId: "sent-1",
      threadId: "t1",
      to: "Alice <alice@acme.com>",
      cc: "dana@acme.com",
      subject: "Re: Launch plan"
    })
    expect(connected.gmail.outbox[0]).toMatchObject({ kind: "send", threadId: "t1" })
  })

  it("rejects a new message without recipients", async () => {
    const connected = await connectGmail()

    const missing = await callTool(connected, "send", { subject: "Hi", body: "x", confirm: true })
    const empty = await callTool(connected, "send", {
      to: "",
      subject: "Hi",
      body: "x",
      confirm: true
    })

    expect([missing.isError, empty.isError]).toEqual([true, true])
    expect(connected.gmail.requests).toEqual([])
  })
})

const inbox = async () => {
  const connected = await connectGmail()
  connected.gmail.add({ ...original, labels: ["INBOX"] })
  connected.gmail.add({ id: "m2", threadId: "t2", labels: ["INBOX", "UNREAD"] })
  connected.gmail.add({ id: "m3", threadId: "t2", labels: ["INBOX", "UNREAD"] })
  return connected
}

describe("gmail organizing", () => {
  it("archives messages in one batch and threads one by one", async () => {
    const connected = await inbox()

    const result = await callTool(connected, "archive", { messageIds: ["m1"], threadIds: ["t2"] })

    expect(result.structuredContent).toEqual({ messages: 1, threads: 1 })
    expect(["m1", "m2", "m3"].map((id) => connected.gmail.labelsOf(id))).toEqual([
      [],
      ["UNREAD"],
      ["UNREAD"]
    ])
    expect(
      connected.gmail.requests.map((request) => request.url.pathname.split("/").slice(-2).join("/"))
    ).toEqual(["messages/batchModify", "t2/modify"])
  })

  it("marks read and unread", async () => {
    const connected = await inbox()

    await callTool(connected, "mark_read", { threadIds: ["t2"] })
    await callTool(connected, "mark_unread", { messageIds: ["m1"] })

    expect(["m1", "m2"].map((id) => connected.gmail.labelsOf(id))).toEqual([
      ["INBOX", "UNREAD"],
      ["INBOX"]
    ])
  })

  it("adds and removes labels by name or id", async () => {
    const connected = await inbox()

    const result = await callTool(connected, "modify_labels", {
      messageIds: ["m1"],
      add: ["receipts", "STARRED"],
      remove: ["Inbox"]
    })

    expect(result.structuredContent).toEqual({ messages: 1, threads: 0 })
    expect(connected.gmail.labelsOf("m1")).toEqual(["Label_1", "STARRED"])
  })

  it("explains unknown labels and missing targets", async () => {
    const connected = await inbox()

    const unknownLabel = await callTool(connected, "modify_labels", {
      threadIds: ["t2"],
      add: ["Taxes"]
    })
    const noLabels = await callTool(connected, "modify_labels", { messageIds: ["m1"] })
    const noTargets = await callTool(connected, "archive", {})

    expect(toolText(unknownLabel)).toBe(
      'Unknown label "Taxes". Call list_labels to see the label names.'
    )
    expect(toolText(noLabels)).toContain("Give at least one label to add or remove.")
    expect(toolText(noTargets)).toContain("Give at least one message id or thread id.")
    expect(connected.gmail.labelsOf("m2")).toEqual(["INBOX", "UNREAD"])
  })
})
