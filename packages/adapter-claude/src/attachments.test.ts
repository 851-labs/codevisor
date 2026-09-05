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

  it("maps attachments: inline images and PDFs, with path notes for every attachment", async () => {
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
            data: Buffer.from("png-bytes"),
            kind: "image",
            mimeType: "image/png",
            name: "shot.png",
            path: "/tmp/att/shot.png"
          },
          {
            data: Buffer.from("pdf-bytes"),
            kind: "file",
            mimeType: "application/pdf",
            name: "doc.pdf",
            path: "/tmp/att/doc.pdf"
          },
          {
            data: Buffer.from("plain"),
            kind: "file",
            mimeType: "text/plain",
            name: "notes.txt",
            path: "/tmp/att/notes.txt"
          },
          {
            data: Buffer.from("heic-bytes"),
            kind: "image",
            mimeType: "image/heic",
            name: "raw.heic",
            path: "/tmp/att/raw.heic"
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
          "[Attached file: /tmp/att/notes.txt (notes.txt, text/plain)]",
          "[Attached file: /tmp/att/raw.heic (raw.heic, image/heic)]"
        ].join("\n\n"),
        type: "text"
      },
      {
        source: {
          data: Buffer.from("png-bytes").toString("base64"),
          media_type: "image/png",
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
            data: Buffer.from("img"),
            kind: "image",
            mimeType: "image/jpeg",
            name: "a.jpg",
            path: "/tmp/att/a.jpg"
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
