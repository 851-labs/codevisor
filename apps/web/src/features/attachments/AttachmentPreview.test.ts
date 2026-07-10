import { describe, expect, it } from "vitest"

import { lightboxCanvasSize } from "./AttachmentPreview"

describe("attachment lightbox canvas", () => {
  it("grows with zoom so enlarged previews remain scrollable", () => {
    expect(lightboxCanvasSize(2)).toEqual({ width: "200%", height: "200%" })
  })

  it("keeps the canvas viewport-sized when zooming out", () => {
    expect(lightboxCanvasSize(0.5)).toEqual({ width: "100%", height: "100%" })
  })
})
