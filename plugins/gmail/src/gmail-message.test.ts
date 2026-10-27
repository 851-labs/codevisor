import { describe, expect, it } from "vitest"

import type { GmailMessage } from "./gmail-api.js"
import {
  maxBodyChars,
  messageDetail,
  messageSummary,
  parseAddresses,
  plainTextBody
} from "./gmail-message.js"

const encoded = (text: string): string => Buffer.from(text, "utf8").toString("base64url")

const message = (payload: GmailMessage["payload"]): GmailMessage => ({
  id: "m1",
  threadId: "t1",
  labelIds: ["INBOX"],
  snippet: "",
  internalDate: "1793102400000",
  payload
})

describe("parseAddresses", () => {
  it("parses display names, quoted names with commas and bare addresses", () => {
    expect(
      parseAddresses('"Doe, Jane" <Jane@Acme.com>, bob@example.com , , Carol <carol@x.io>')
    ).toEqual([
      { email: "jane@acme.com", name: "Doe, Jane" },
      { email: "bob@example.com", name: "" },
      { email: "carol@x.io", name: "Carol" }
    ])
    expect(parseAddresses("")).toEqual([])
  })
})

describe("message bodies", () => {
  it("prefers the nested text/plain part", () => {
    const payload = {
      mimeType: "multipart/mixed",
      parts: [
        {
          mimeType: "multipart/alternative",
          parts: [{ mimeType: "text/plain", body: { data: encoded("héllo\n") } }]
        },
        { mimeType: "application/pdf", body: {} }
      ]
    }

    expect(plainTextBody(payload)).toBe("héllo\n")
  })

  it("falls back to readable text from html", () => {
    const html =
      "<html><style>p{}</style><script>x()</script><p>Hi &amp; welcome</p><br/><div>a &lt;b&gt; &quot;c&quot; &#39;d&#39;&nbsp;e</div></html>"

    expect(plainTextBody({ mimeType: "text/html", body: { data: encoded(html) } })).toBe(
      "Hi & welcome\n\na <b> \"c\" 'd' e"
    )
    expect(plainTextBody({ mimeType: "multipart/alternative", parts: [] })).toBe("")
  })

  it("truncates very long bodies", () => {
    const long = "x".repeat(maxBodyChars + 10)

    const detail = messageDetail(message({ mimeType: "text/plain", body: { data: encoded(long) } }))

    expect(detail.body).toBe(`${"x".repeat(maxBodyChars)}\n…[truncated]`)
  })

  it("summarizes a message without headers", () => {
    expect(messageSummary(message({}))).toMatchObject({
      from: { email: "", name: "" },
      to: [],
      cc: [],
      subject: "",
      receivedAt: "2026-10-27T12:00:00.000Z"
    })
  })
})
