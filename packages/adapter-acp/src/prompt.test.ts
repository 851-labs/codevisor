import { describe, expect, it } from "vitest"
import {
  normalizePromptInput,
  withAttachmentNotes,
  type PromptAttachmentInput
} from "@codevisor/agent-runtime"
import { acpPrompt } from "./index.js"

describe("prompt attachments", () => {
  const image: PromptAttachmentInput = {
    data: Buffer.from("img"),
    kind: "image",
    mimeType: "image/png",
    name: "shot.png",
    path: "/tmp/att/shot.png"
  }
  const file: PromptAttachmentInput = {
    data: Buffer.from("notes"),
    kind: "file",
    mimeType: "text/plain",
    name: "notes.txt",
    path: "/tmp/att/notes.txt"
  }

  it("normalizes prompt input from strings and structured input", () => {
    expect(normalizePromptInput("hello")).toEqual({ text: "hello" })
    const input = { attachments: [image], text: "hi" }
    expect(normalizePromptInput(input)).toBe(input)
  })

  it("appends path notes for attachments, skipping empty text", () => {
    expect(withAttachmentNotes("hello", [])).toBe("hello")
    expect(withAttachmentNotes("hello", [file])).toBe(
      "hello\n\n[Attached file: /tmp/att/notes.txt (notes.txt, text/plain)]"
    )
    expect(withAttachmentNotes("", [file])).toBe(
      "[Attached file: /tmp/att/notes.txt (notes.txt, text/plain)]"
    )
  })

  it("builds ACP prompt blocks: resource_link for every file, inline images when supported", () => {
    expect(acpPrompt({ attachments: [image, file], text: "look" }, { image: true })).toEqual([
      { text: "look", type: "text" },
      {
        mimeType: "image/png",
        name: "shot.png",
        size: 3,
        type: "resource_link",
        uri: "file:///tmp/att/shot.png"
      },
      { data: Buffer.from("img").toString("base64"), mimeType: "image/png", type: "image" },
      {
        mimeType: "text/plain",
        name: "notes.txt",
        size: 5,
        type: "resource_link",
        uri: "file:///tmp/att/notes.txt"
      }
    ])
    // No image capability: the image still arrives as a readable resource_link.
    expect(acpPrompt({ attachments: [image], text: "look" }, {})).toEqual([
      { text: "look", type: "text" },
      {
        mimeType: "image/png",
        name: "shot.png",
        size: 3,
        type: "resource_link",
        uri: "file:///tmp/att/shot.png"
      }
    ])
    // Image-only prompts drop the empty text block.
    expect(acpPrompt({ attachments: [image], text: "" }, { image: true })).toEqual([
      {
        mimeType: "image/png",
        name: "shot.png",
        size: 3,
        type: "resource_link",
        uri: "file:///tmp/att/shot.png"
      },
      { data: Buffer.from("img").toString("base64"), mimeType: "image/png", type: "image" }
    ])
    expect(acpPrompt({ text: "plain" }, { image: true })).toEqual([{ text: "plain", type: "text" }])
  })
})
