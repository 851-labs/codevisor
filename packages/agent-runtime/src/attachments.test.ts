import { describe, expect, it } from "vitest"

import { attachmentPathNote, INLINE_IMAGE_MEDIA_TYPES, withAttachmentNotes } from "./attachments.js"

describe("attachments", () => {
  it("names the Anthropic-inline image media types", () => {
    expect([...INLINE_IMAGE_MEDIA_TYPES].toSorted()).toEqual([
      "image/gif",
      "image/jpeg",
      "image/png",
      "image/webp"
    ])
  })

  it("builds path notes and marks oversized inline omissions", () => {
    expect(
      attachmentPathNote({
        kind: "file",
        mimeType: "text/plain",
        name: "notes.txt",
        path: "/tmp/notes.txt",
        sizeBytes: 5
      })
    ).toBe("[Attached file: /tmp/notes.txt (notes.txt, text/plain)]")
    expect(
      attachmentPathNote({
        inlineOmitted: true,
        kind: "file",
        mimeType: "application/pdf",
        name: "big.pdf",
        path: "/tmp/big.pdf",
        sizeBytes: 90_000_000
      })
    ).toBe(
      [
        "[Attached file: /tmp/big.pdf (big.pdf, application/pdf)]",
        "[big.pdf is too large to show inline. Read it from the path above if you need its contents, and tell the user it was not embedded.]"
      ].join("\n")
    )
  })

  it("leaves prompt text alone without attachments and joins notes otherwise", () => {
    expect(withAttachmentNotes("hello", [])).toBe("hello")
    expect(
      withAttachmentNotes("look", [
        {
          kind: "file",
          mimeType: "text/plain",
          name: "a.txt",
          path: "/tmp/a.txt",
          sizeBytes: 1
        },
        {
          kind: "file",
          mimeType: "text/plain",
          name: "b.txt",
          path: "/tmp/b.txt",
          sizeBytes: 1
        }
      ])
    ).toBe(
      [
        "look",
        "[Attached file: /tmp/a.txt (a.txt, text/plain)]",
        "[Attached file: /tmp/b.txt (b.txt, text/plain)]"
      ].join("\n\n")
    )
  })
})
