import { afterEach, describe, expect, it, vi } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  resultMessage,
  run
} from "./test-support.js"

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("maps attachments: server-sized inline images and PDFs, with path notes for every attachment", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const createPromise = run(provider.createSession(definition, "/tmp", async () => undefined))
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(
      created.handle.prompt({
        text: "look at these",
        attachments: [
          {
            // The server re-encoded an oversized PNG, so the inline type wins.
            inline: { data: Buffer.from("jpeg-bytes"), mimeType: "image/jpeg" },
            kind: "image",
            mimeType: "image/png",
            name: "shot.png",
            path: "/tmp/att/shot.png",
            sizeBytes: 40_000_000
          },
          {
            inline: { data: Buffer.from("pdf-bytes"), mimeType: "application/pdf" },
            kind: "file",
            mimeType: "application/pdf",
            name: "doc.pdf",
            path: "/tmp/att/doc.pdf",
            sizeBytes: 9
          },
          {
            inlineOmitted: true,
            kind: "file",
            mimeType: "application/pdf",
            name: "big.pdf",
            path: "/tmp/att/big.pdf",
            sizeBytes: 90_000_000
          },
          {
            kind: "file",
            mimeType: "text/plain",
            name: "notes.txt",
            path: "/tmp/att/notes.txt",
            sizeBytes: 5
          },
          {
            kind: "image",
            mimeType: "image/heic",
            name: "raw.heic",
            path: "/tmp/att/raw.heic",
            sizeBytes: 10
          }
        ]
      })
    )
    await fake.nextPrompt()
    expect(fake.userMessages[0]?.message.content).toEqual([
      {
        text: [
          "look at these",
          "[Attached file: /tmp/att/shot.png (shot.png, image/png)]",
          "[Attached file: /tmp/att/doc.pdf (doc.pdf, application/pdf)]",
          "[Attached file: /tmp/att/big.pdf (big.pdf, application/pdf)]\n[big.pdf is too large to show inline. Read it from the path above if you need its contents, and tell the user it was not embedded.]",
          "[Attached file: /tmp/att/notes.txt (notes.txt, text/plain)]",
          "[Attached file: /tmp/att/raw.heic (raw.heic, image/heic)]"
        ].join("\n\n"),
        type: "text"
      },
      {
        source: {
          data: Buffer.from("jpeg-bytes").toString("base64"),
          media_type: "image/jpeg",
          type: "base64"
        },
        type: "image"
      },
      {
        source: {
          data: Buffer.from("pdf-bytes").toString("base64"),
          media_type: "application/pdf",
          type: "base64"
        },
        type: "document"
      }
    ])
    fake.push(resultMessage())
    await promptPromise
  })

  it("notes the temp-file path even for an image-only prompt", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const createPromise = run(provider.createSession(definition, "/tmp", async () => undefined))
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(
      created.handle.prompt({
        text: "",
        attachments: [
          {
            inline: { data: Buffer.from("img"), mimeType: "image/jpeg" },
            kind: "image",
            mimeType: "image/jpeg",
            name: "a.jpg",
            path: "/tmp/att/a.jpg",
            sizeBytes: 3
          }
        ]
      })
    )
    await fake.nextPrompt()
    expect(fake.userMessages[0]?.message.content).toEqual([
      {
        text: "[Attached file: /tmp/att/a.jpg (a.jpg, image/jpeg)]",
        type: "text"
      },
      {
        source: {
          data: Buffer.from("img").toString("base64"),
          media_type: "image/jpeg",
          type: "base64"
        },
        type: "image"
      }
    ])
    fake.push(resultMessage())
    await promptPromise
  })
})
