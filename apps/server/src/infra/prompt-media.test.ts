import { mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import sharp from "sharp"
import { afterAll, describe, expect, it } from "vitest"

import {
  INLINE_IMAGE_MAX_BASE64_BYTES,
  INLINE_IMAGE_MAX_DIMENSION,
  INLINE_PDF_MAX_BYTES,
  inlineSizing
} from "./prompt-media.js"

const root = mkdtempSync(join(tmpdir(), "codevisor-prompt-media-"))
afterAll(() => rmSync(root, { force: true, recursive: true }))

const fixture = (name: string, data: Buffer) => {
  const path = join(root, name)
  writeFileSync(path, data)
  return { path, sizeBytes: statSync(path).size }
}

/// Random pixels defeat compression, so the fixture's size is predictable.
const noisePng = async (width: number, height: number): Promise<Buffer> => {
  const pixels = Buffer.alloc(width * height * 3)
  let seed = 7
  for (let index = 0; index < pixels.length; index += 1) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    pixels[index] = seed & 0xff
  }
  return await sharp(pixels, { raw: { width, height, channels: 3 } })
    .png({ compressionLevel: 0 })
    .toBuffer()
}

describe("inlineSizing", () => {
  it("passes small images through untouched", async () => {
    const bytes = await sharp({
      create: { width: 40, height: 20, channels: 3, background: "#336699" }
    })
      .png()
      .toBuffer()
    const image = fixture("small.png", bytes)
    expect(await inlineSizing({ ...image, kind: "image", mimeType: "image/png" })).toEqual({
      inline: { data: bytes, mimeType: "image/png" }
    })
  })

  it("re-encodes oversized images within the provider budget", async () => {
    const image = fixture("huge.png", await noisePng(3000, 1500))
    expect(image.sizeBytes).toBeGreaterThan(INLINE_IMAGE_MAX_BASE64_BYTES)

    const sized = await inlineSizing({ ...image, kind: "image", mimeType: "image/png" })
    expect(sized.inlineOmitted).toBeUndefined()
    const inline = sized.inline!
    expect(Math.ceil(inline.data.byteLength / 3) * 4).toBeLessThanOrEqual(
      INLINE_IMAGE_MAX_BASE64_BYTES
    )
    const metadata = await sharp(inline.data).metadata()
    expect(metadata.format).toBe(inline.mimeType === "image/png" ? "png" : "jpeg")
    expect(Math.max(metadata.width, metadata.height)).toBeLessThanOrEqual(
      INLINE_IMAGE_MAX_DIMENSION
    )
    // Aspect ratio survives the resize.
    expect(metadata.width / metadata.height).toBeCloseTo(2, 1)
  })

  it("sizes rotated photos by their displayed orientation", async () => {
    // Stored landscape, displayed portrait (EXIF orientation 6).
    const stored = await sharp(await noisePng(3000, 1500))
      .jpeg({ quality: 100 })
      .withMetadata({ orientation: 6 })
      .toBuffer()
    const image = fixture("rotated.jpg", stored)
    const inline = (await inlineSizing({ ...image, kind: "image", mimeType: "image/jpeg" })).inline!
    const metadata = await sharp(inline.data).metadata()
    expect(metadata.height / metadata.width).toBeCloseTo(2, 1)
    expect(metadata.height).toBeLessThanOrEqual(INLINE_IMAGE_MAX_DIMENSION)
  })

  it("omits images the decoder cannot read", async () => {
    const image = fixture("broken.png", Buffer.from("not really a png"))
    expect(await inlineSizing({ ...image, kind: "image", mimeType: "image/png" })).toEqual({
      inlineOmitted: true
    })
  })

  it("inlines PDFs only up to the document cap", async () => {
    const small = fixture("small.pdf", Buffer.from("%PDF-1.4 tiny"))
    expect(await inlineSizing({ ...small, kind: "file", mimeType: "application/pdf" })).toEqual({
      inline: { data: Buffer.from("%PDF-1.4 tiny"), mimeType: "application/pdf" }
    })
    // Only the size matters, so a sparse stand-in avoids writing 20 MB.
    expect(
      await inlineSizing({
        path: join(root, "never-read.pdf"),
        kind: "file",
        mimeType: "application/pdf",
        sizeBytes: INLINE_PDF_MAX_BYTES + 1
      })
    ).toEqual({ inlineOmitted: true })
  })

  it("never reads other files", async () => {
    // The path does not exist: reading it would throw.
    expect(
      await inlineSizing({
        path: join(root, "missing.mp4"),
        kind: "file",
        mimeType: "video/mp4",
        sizeBytes: 400 * 1024 * 1024
      })
    ).toEqual({})
    expect(
      await inlineSizing({
        path: join(root, "missing.heic"),
        kind: "image",
        mimeType: "image/heic",
        sizeBytes: 10
      })
    ).toEqual({})
  })
})
