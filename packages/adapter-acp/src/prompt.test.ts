import type { PromptAttachmentInput } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

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
