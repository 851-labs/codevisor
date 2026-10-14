import sharp from "sharp"

export interface ToolIconAsset {
  readonly contentType: "image/png" | "image/x-icon"
  readonly data: Uint8Array
}

const ICON_PIXELS = 128

type ImageFormat = "png" | "jpeg" | "gif" | "webp" | "ico" | "svg"

const startsWith = (data: Uint8Array, bytes: ReadonlyArray<number>, offset = 0): boolean =>
  data.length >= offset + bytes.length &&
  bytes.every((byte, index) => data[offset + index] === byte)

export const sniffImageFormat = (data: Uint8Array): ImageFormat | undefined => {
  if (startsWith(data, [0x89, 0x50, 0x4e, 0x47])) return "png"
  if (startsWith(data, [0xff, 0xd8, 0xff])) return "jpeg"
  if (startsWith(data, [0x47, 0x49, 0x46, 0x38])) return "gif"
  if (startsWith(data, [0x52, 0x49, 0x46, 0x46]) && startsWith(data, [0x57, 0x45, 0x42, 0x50], 8))
    return "webp"
  if (startsWith(data, [0x00, 0x00, 0x01, 0x00])) return "ico"
  const head = new TextDecoder().decode(data.subarray(0, 1024)).trimStart()
  if (/^(?:<\?xml[^>]*>\s*)?(?:<!--[\s\S]*?-->\s*)*<svg[\s>]/i.test(head)) return "svg"
  return undefined
}

export const isInertSvg = (source: string): boolean => {
  if (/<(?:script|foreignObject|iframe|object|embed)\b/i.test(source)) return false
  if (/<!DOCTYPE|<!ENTITY|@import\b/i.test(source)) return false
  for (const match of source.matchAll(/(?:href|xlink:href)\s*=\s*["']([^"']*)["']/gi)) {
    if (!match[1]!.startsWith("#")) return false
  }
  for (const match of source.matchAll(/url\(\s*["']?([^)'"\s]+)["']?\s*\)/gi)) {
    if (!match[1]!.startsWith("#")) return false
  }
  return true
}

export const normalizeIcon = async (data: Uint8Array): Promise<ToolIconAsset | undefined> => {
  const format = sniffImageFormat(data)
  if (format === undefined) return undefined
  if (format === "ico") return { contentType: "image/x-icon", data }
  if (format === "svg" && !isInertSvg(new TextDecoder().decode(data))) return undefined
  try {
    const png = await sharp(data, {
      density: format === "svg" ? 192 : 72,
      limitInputPixels: 16_777_216,
      animated: false
    })
      .resize({ fit: "inside", width: ICON_PIXELS, height: ICON_PIXELS, withoutEnlargement: true })
      .png({ compressionLevel: 9 })
      .toBuffer()
    return { contentType: "image/png", data: new Uint8Array(png) }
  } catch {
    return undefined
  }
}
