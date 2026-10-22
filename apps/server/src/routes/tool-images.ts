import { createHash } from "node:crypto"

import type { RuntimeEvent } from "@codevisor/agent-runtime"
import type { AttachmentRef } from "@codevisor/api"

import { run, type CodevisorServerServices } from "../server-context.js"
import { isRecord } from "../unknown-values.js"
import { attachmentRef, captureAssistantFile } from "./assistant-files.js"

const maxImagesPerEvent = 8
const maxImageBytes = 20 * 1024 * 1024
const maxDepth = 4

export interface InlineImage {
  readonly data: string
  readonly mimeType: string
}

const inlineImage = (value: Readonly<Record<string, unknown>>): InlineImage | undefined => {
  if (value.type !== "image") return undefined
  if (typeof value.data === "string" && typeof value.mimeType === "string") {
    return { data: value.data, mimeType: value.mimeType }
  }
  const source = value.source
  return isRecord(source) &&
    source.type === "base64" &&
    typeof source.data === "string" &&
    typeof source.media_type === "string"
    ? { data: source.data, mimeType: source.media_type }
    : undefined
}

const storableImage = (image: InlineImage): boolean =>
  image.mimeType.startsWith("image/") &&
  image.data.length > 0 &&
  Math.floor((image.data.length * 3) / 4) <= maxImageBytes

const collectImages = (value: unknown, depth: number, found: Map<object, InlineImage>): void => {
  if (depth > maxDepth || found.size >= maxImagesPerEvent) return
  if (Array.isArray(value)) {
    for (const element of value) collectImages(element, depth + 1, found)
  } else if (isRecord(value)) {
    const image = inlineImage(value)
    if (image !== undefined) {
      if (storableImage(image)) found.set(value, image)
      return
    }
    for (const child of Object.values(value)) collectImages(child, depth + 1, found)
  }
}

export const toolImageCandidates = (
  payload: Readonly<Record<string, unknown>>
): Map<object, InlineImage> => {
  const found = new Map<object, InlineImage>()
  if (payload.sessionUpdate !== "tool_call_update" && payload.sessionUpdate !== "tool_call") {
    return found
  }
  collectImages(payload.rawOutput, 0, found)
  collectImages(payload.content, 0, found)
  return found
}

const replaceImages = (value: unknown, saved: ReadonlyMap<object, AttachmentRef>): unknown => {
  if (Array.isArray(value)) return value.map((element) => replaceImages(element, saved))
  if (!isRecord(value)) return value
  const attachment = saved.get(value)
  if (attachment !== undefined) {
    return isRecord(value.source)
      ? { ...value, source: { ...value.source, data: "" }, attachment }
      : { ...value, data: "", attachment }
  }
  return Object.fromEntries(
    Object.entries(value).map(([key, child]) => [key, replaceImages(child, saved)])
  )
}

const imageFileId = (event: RuntimeEvent, toolCallId: unknown, image: InlineImage): string =>
  "tool-image-" +
  createHash("sha256")
    .update(JSON.stringify([event.subjectId, toolCallId, image.data]))
    .digest("hex")

const imageName = (image: InlineImage): string =>
  `Tool image.${image.mimeType.slice("image/".length).split(/[+;]/)[0]}`

export const persistToolImages = async (
  services: CodevisorServerServices,
  event: RuntimeEvent,
  payload: Readonly<Record<string, unknown>>,
  candidates: ReadonlyMap<object, InlineImage>
): Promise<RuntimeEvent> => {
  const saved = new Map<object, AttachmentRef>()
  for (const [node, image] of candidates) {
    try {
      const fileId = imageFileId(event, payload.toolCallId, image)
      const existing = await run(services.db.getFileMetadata(fileId))
      let attachment: AttachmentRef
      if (existing === undefined) {
        attachment = await captureAssistantFile(
          services,
          {
            data: Buffer.from(image.data, "base64"),
            name: imageName(image),
            mimeType: image.mimeType
          },
          [],
          fileId
        )
      } else {
        attachment = attachmentRef(existing)
      }
      saved.set(node, attachment)
    } catch (cause) {
      console.error("Could not preserve tool image:", cause)
    }
  }
  if (saved.size === 0) return event
  return {
    ...event,
    payload: {
      ...payload,
      rawOutput: replaceImages(payload.rawOutput, saved),
      content: replaceImages(payload.content, saved),
      toolImages: [...saved.values()]
    }
  }
}
