import { describe, expect, it } from "vitest"

import {
  attachmentsOf,
  maxBodyChars,
  plainTextBody,
  truncatedBody,
  withoutQuotedHistory
} from "./gmail-body.js"
import { threadSummary } from "./gmail-message.js"

const encoded = (text: string): string => Buffer.from(text, "utf8").toString("base64url")

describe("message bodies", () => {
  it("skips text parts that are attachments and returns nothing when no body exists", () => {
    const payload = {
      mimeType: "multipart/mixed",
      parts: [
        { mimeType: "text/plain", filename: "notes.txt", body: { data: encoded("file"), size: 4 } },
        { mimeType: "application/octet-stream", filename: "blob" }
      ]
    }

    expect(plainTextBody(payload)).toBe("")
    expect(attachmentsOf(payload)).toEqual([
      { filename: "notes.txt", mimeType: "text/plain", size: 4 },
      { filename: "blob", mimeType: "application/octet-stream", size: 0 }
    ])
    expect(attachmentsOf({ parts: [{ filename: "raw" }] })).toEqual([
      { filename: "raw", mimeType: "application/octet-stream", size: 0 }
    ])
  })

  it("decodes HTML entities and leaves impossible code points alone", () => {
    const html = encoded("<p>&#99999999; &#x110000; &amp;lt; &apos;</p>")

    expect(plainTextBody({ mimeType: "text/html", body: { data: html } })).toBe(
      "&#99999999; &#x110000; &lt; '"
    )
  })

  it("marks how much of a long body was cut", () => {
    const body = "x".repeat(maxBodyChars + 5)

    expect(truncatedBody(body)).toBe(`${"x".repeat(maxBodyChars)}\n[truncated: 5 more characters]`)
  })
})

describe("quoted history", () => {
  it.each([
    {
      name: "a one-line attribution",
      body: "Sure.\nOn Mon, Ana wrote:\n> hi",
      trimmed: "Sure.\n[quoted history hidden]"
    },
    {
      name: "an attribution without On",
      body: "Sure.\n\nAna <ana@x.io> wrote:\n> hi\n\n> there",
      trimmed: "Sure.\n[quoted history hidden]"
    },
    {
      name: "a quote with nothing above it",
      body: "On Mon, Ana wrote:\n> hi",
      trimmed: "On Mon, Ana wrote:\n> hi"
    },
    {
      name: "inline answers between quotes",
      body: "On Mon, Ana wrote:\n> Friday?\nYes.\n> Time?\nNoon.",
      trimmed: "On Mon, Ana wrote:\n> Friday?\nYes.\n> Time?\nNoon."
    },
    {
      name: "an attribution with nothing quoted after it",
      body: "Ana wrote:",
      trimmed: "Ana wrote:"
    }
  ])("handles $name", ({ body, trimmed }) => {
    expect(withoutQuotedHistory(body)).toBe(trimmed)
  })
})

describe("thread summaries", () => {
  it("summarizes a thread with no messages left", () => {
    expect(threadSummary({ id: "t1", messages: [] })).toEqual({
      id: "t1",
      subject: "",
      from: [],
      messages: 0,
      date: "",
      snippet: "",
      labels: []
    })
  })
})
