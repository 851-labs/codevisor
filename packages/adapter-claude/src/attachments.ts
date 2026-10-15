import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk"
import { withAttachmentNotes, type PromptInput } from "@codevisor/agent-runtime"

export type ClaudeContentBlock = Exclude<SDKUserMessage["message"]["content"], string>[number]

type ImageMediaType = "image/jpeg" | "image/png" | "image/gif" | "image/webp"

const IMAGE_MEDIA_TYPES: ReadonlyArray<string> = [
  "image/jpeg",
  "image/png",
  "image/gif",
  "image/webp"
] satisfies ReadonlyArray<ImageMediaType>

const isImageMediaType = (mimeType: string): mimeType is ImageMediaType =>
  IMAGE_MEDIA_TYPES.includes(mimeType)

const inlineBlock = (content: {
  readonly mimeType: string
  readonly data: Buffer
}): ClaudeContentBlock | undefined => {
  const data = content.data.toString("base64")
  if (content.mimeType === "application/pdf") {
    return { source: { data, media_type: "application/pdf", type: "base64" }, type: "document" }
  }
  if (!isImageMediaType(content.mimeType)) return undefined
  return { source: { data, media_type: content.mimeType, type: "base64" }, type: "image" }
}

export const claudeContent = (input: PromptInput): Array<ClaudeContentBlock> => {
  const attachments = input.attachments ?? []
  const media = attachments.flatMap((attachment) => {
    const block = attachment.inline === undefined ? undefined : inlineBlock(attachment.inline)
    return block === undefined ? [] : [block]
  })
  const text = withAttachmentNotes(input.text, attachments)
  return text !== "" || media.length === 0 ? [{ text, type: "text" }, ...media] : media
}
