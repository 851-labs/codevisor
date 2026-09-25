import { readFile } from "node:fs/promises"

import { INLINE_IMAGE_MEDIA_TYPES, type PromptAttachmentInput } from "@codevisor/agent-runtime"
import sharp from "sharp"

/// Sizes attachments for inline embedding, following OpenCode's
/// `Image.normalize`: providers cap inline images (Anthropic: ~5 MB, long
/// edge ~2000px) and whole requests (32 MB), so sending originals fails at
/// the API once attachments can be hundreds of megabytes.

/// Base64 budget for one inline image.
export const INLINE_IMAGE_MAX_BASE64_BYTES = 5 * 1024 * 1024
/// Longest allowed edge for an inline image, in either direction.
export const INLINE_IMAGE_MAX_DIMENSION = 2000
/// Largest PDF embedded as a document block. Base64 of this stays under the
/// 32 MB Anthropic request cap (and the shared-account gateway's body cap);
/// bigger PDFs are referenced by path only.
export const INLINE_PDF_MAX_BYTES = 20 * 1024 * 1024

const JPEG_QUALITIES = [80, 85, 70, 55, 40]
const MAX_RESIZE_PASSES = 32

const base64Length = (bytes: number): number => Math.ceil(bytes / 3) * 4

type InlineSizing = Pick<PromptAttachmentInput, "inline" | "inlineOmitted">

/// Candidate sizes: first the largest that fits the dimension cap, then 0.75×
/// steps, de-duplicated once they bottom out at 1px.
const candidateSizes = (
  width: number,
  height: number
): Array<{ readonly width: number; readonly height: number }> => {
  const scale = Math.min(1, INLINE_IMAGE_MAX_DIMENSION / width, INLINE_IMAGE_MAX_DIMENSION / height)
  const sizes = [
    {
      width: Math.max(1, Math.round(width * scale)),
      height: Math.max(1, Math.round(height * scale))
    }
  ]
  while (sizes.length < MAX_RESIZE_PASSES) {
    const previous = sizes[sizes.length - 1]!
    const next = {
      width: Math.max(1, Math.floor(previous.width * 0.75)),
      height: Math.max(1, Math.floor(previous.height * 0.75))
    }
    if (next.width === previous.width && next.height === previous.height) break
    sizes.push(next)
  }
  return sizes
}

const normalizeImage = async (
  path: string,
  mimeType: string,
  sizeBytes: number
): Promise<InlineSizing> => {
  try {
    const metadata = await sharp(path).metadata()
    // EXIF orientations 5–8 swap the displayed width and height.
    const rotated = (metadata.orientation ?? 1) >= 5
    const width = rotated ? metadata.height : metadata.width
    const height = rotated ? metadata.width : metadata.height
    if (
      width <= INLINE_IMAGE_MAX_DIMENSION &&
      height <= INLINE_IMAGE_MAX_DIMENSION &&
      base64Length(sizeBytes) <= INLINE_IMAGE_MAX_BASE64_BYTES
    ) {
      return { inline: { data: await readFile(path), mimeType } }
    }
    for (const size of candidateSizes(width, height)) {
      const resized = sharp(path).rotate().resize(size.width, size.height, { fit: "fill" })
      const encodings: Array<() => Promise<{ data: Buffer; mimeType: string }>> = [
        async () => ({ data: await resized.clone().png().toBuffer(), mimeType: "image/png" }),
        ...JPEG_QUALITIES.map((quality) => async () => ({
          data: await resized
            .clone()
            .flatten({ background: "#ffffff" })
            .jpeg({ quality })
            .toBuffer(),
          mimeType: "image/jpeg"
        }))
      ]
      for (const encode of encodings) {
        const candidate = await encode()
        if (base64Length(candidate.data.byteLength) <= INLINE_IMAGE_MAX_BASE64_BYTES) {
          return { inline: candidate }
        }
      }
    }
  } catch {
    // An image the decoder rejects would be rejected by the provider too.
  }
  return { inlineOmitted: true }
}

/// Decides what a provider may embed for one materialized attachment. Only
/// embeddable kinds are ever read into memory; everything else is path-only.
export const inlineSizing = async (attachment: {
  readonly path: string
  readonly kind: "image" | "file"
  readonly mimeType: string
  readonly sizeBytes: number
}): Promise<InlineSizing> => {
  if (attachment.mimeType === "application/pdf") {
    return attachment.sizeBytes <= INLINE_PDF_MAX_BYTES
      ? { inline: { data: await readFile(attachment.path), mimeType: "application/pdf" } }
      : { inlineOmitted: true }
  }
  if (attachment.kind === "image" && INLINE_IMAGE_MEDIA_TYPES.has(attachment.mimeType)) {
    return await normalizeImage(attachment.path, attachment.mimeType, attachment.sizeBytes)
  }
  return {}
}
