import { describe, expect, it } from "vitest"

import {
  hasVisualAttachmentPreview,
  isVideoAttachment,
  lightboxCanvasSize
} from "./AttachmentPreview"

describe("attachment lightbox canvas", () => {
  it("grows with zoom so enlarged previews remain scrollable", () => {
    expect(lightboxCanvasSize(2)).toEqual({ width: "200%", height: "200%" })
  })

  it("keeps the canvas viewport-sized when zooming out", () => {
    expect(lightboxCanvasSize(0.5)).toEqual({ width: "100%", height: "100%" })
  })
})

describe("video attachment previews", () => {
  it("recognizes video MIME types and common video extensions", () => {
    expect(isVideoAttachment({ mimeType: "video/quicktime", name: "recording.mov" })).toBe(true)
    expect(isVideoAttachment({ mimeType: "application/octet-stream", name: "recording.mp4" })).toBe(
      true
    )
  })

  it("treats videos as visual attachments even though their stored kind is file", () => {
    expect(
      hasVisualAttachmentPreview({
        kind: "file",
        mimeType: "video/mp4",
        name: "demo.mp4",
        sizeBytes: 1024
      })
    ).toBe(true)
  })
})
