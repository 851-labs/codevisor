const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/u
// oxlint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f-\u009f]/u
const utf8 = new TextDecoder("utf-8", { fatal: true })

export const decodeBase64Text = (
  encoded: string,
  maxBytes = Number.POSITIVE_INFINITY
): string | undefined => {
  if (!wellFormedBase64(encoded)) return undefined

  const bytes = Buffer.from(encoded, "base64")
  if (bytes.length > maxBytes) return undefined

  const text = decodeUtf8(bytes)
  if (text === undefined || CONTROL.test(text)) return undefined
  return text
}

const wellFormedBase64 = (encoded: string): boolean => {
  if (!BASE64.test(encoded)) return false
  if (encoded.endsWith("=")) return encoded.length % 4 === 0
  return encoded.length % 4 !== 1
}

const decodeUtf8 = (bytes: Uint8Array): string | undefined => {
  try {
    return utf8.decode(bytes)
  } catch {
    return undefined
  }
}
