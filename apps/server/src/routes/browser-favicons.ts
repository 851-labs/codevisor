import { createHash } from "node:crypto"
import type { IncomingMessage, ServerResponse } from "node:http"

import { BrowserFaviconUpload, decode } from "@codevisor/api"

import {
  BoundedBody,
  HttpFailure,
  run,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

export const maxBrowserFaviconBytes = 131_072
export const maxBrowserFaviconPixels = 256

export const routeBrowserFavicon = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  sha256: string
): Promise<boolean> => {
  if (request.method === "PUT") {
    const data = await readUpload(request)
    await run(services.db.putBrowserFavicon(sha256, faviconBytes(sha256, data)))
    writeJson(response, 200, {})
    return true
  }
  if (request.method === "GET") {
    const data = await run(services.db.getBrowserFavicon(sha256))
    writeJson(response, 200, { favicon: data?.toString("base64") ?? null })
    return true
  }
  return false
}

const maxUploadBodyBytes = Math.ceil(maxBrowserFaviconBytes / 3) * 4 + 1024

const pngSignature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

const readUpload = async (request: IncomingMessage): Promise<string> => {
  const received = new BoundedBody(maxUploadBodyBytes)
  for await (const chunk of request)
    if (!received.accept(chunk)) throw new HttpFailure(413, "Favicons must be 128 KB or less")
  return uploadData(received.text())
}

const uploadData = (text: string): string => {
  try {
    return decode(BrowserFaviconUpload)(JSON.parse(text)).data
  } catch {
    throw new HttpFailure(400, "Invalid favicon upload")
  }
}

const faviconBytes = (sha256: string, base64: string): Buffer => {
  const data = Buffer.from(base64, "base64")
  if (!isStorableFavicon(data))
    throw new HttpFailure(400, "Favicons must be PNG images of at most 256×256 and 128 KB")
  if (digest(data) !== sha256) throw new HttpFailure(400, "Favicon does not match its hash")
  return data
}

const isStorableFavicon = (data: Buffer): boolean =>
  data.byteLength <= maxBrowserFaviconBytes && isPng(data) && fitsFaviconSize(data)

const isPng = (data: Buffer): boolean =>
  data.byteLength >= 24 &&
  data.subarray(0, pngSignature.byteLength).equals(pngSignature) &&
  data.toString("latin1", 12, 16) === "IHDR"

const fitsFaviconSize = (data: Buffer): boolean =>
  [data.readUInt32BE(16), data.readUInt32BE(20)].every(
    (side) => side > 0 && side <= maxBrowserFaviconPixels
  )

const digest = (data: Buffer): string => createHash("sha256").update(data).digest("hex")
