import { describe, expect, it } from "vitest"

import {
  boundedAttachmentPreviewSize,
  hasVisualAttachmentPreview,
  isVideoAttachment,
  lightboxCanvasSize
} from "./AttachmentPreview"

describe("attachment preview sizing", () => {
  it("preserves landscape media ratios within the width bound", () => {
    expect(boundedAttachmentPreviewSize(16 / 9)).toEqual({ width: 320, height: 180 })
  })

  it("preserves portrait and square ratios within the height bound", () => {
    expect(boundedAttachmentPreviewSize(9 / 16)).toEqual({ width: 157.5, height: 280 })
    expect(boundedAttachmentPreviewSize(1)).toEqual({ width: 280, height: 280 })
  })

  it("uses a safe fallback for missing or invalid dimensions", () => {
    expect(boundedAttachmentPreviewSize(undefined)).toEqual({ width: 320, height: 180 })
    expect(boundedAttachmentPreviewSize(Number.POSITIVE_INFINITY, 320, 280, 1)).toEqual({
      width: 280,
      height: 280
    })
  })
})

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
