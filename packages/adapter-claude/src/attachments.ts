import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk"
import {
  INLINE_IMAGE_MEDIA_TYPES,
  withAttachmentNotes,
  type PromptAttachmentInput,
  type PromptInput
} from "@codevisor/agent-runtime"

export type ClaudeContentBlock = Exclude<SDKUserMessage["message"]["content"], string>[number]

const isInlineForClaude = (attachment: PromptAttachmentInput): boolean =>
  (attachment.kind === "image" && INLINE_IMAGE_MEDIA_TYPES.has(attachment.mimeType)) ||
  attachment.mimeType === "application/pdf"

/// Builds the user-message content blocks: inline what the Anthropic API
/// accepts (images, PDFs) so the model sees the content, and note EVERY
/// attachment's materialized temp-file path in the text — including inline
/// images — so the agent also knows where each file lives on disk (to copy it
/// into the repo, re-read it, etc.).
export const claudeContent = (input: PromptInput): Array<ClaudeContentBlock> => {
  const attachments = input.attachments ?? []
  const inline = attachments.filter(isInlineForClaude)
  const text = withAttachmentNotes(input.text, attachments)
  const blocks: Array<ClaudeContentBlock> = []
  if (text !== "" || inline.length === 0) {
    blocks.push({ text, type: "text" })
  }
  for (const attachment of inline) {
    const data = attachment.data.toString("base64")
    blocks.push(
      attachment.mimeType === "application/pdf"
        ? { source: { data, media_type: "application/pdf", type: "base64" }, type: "document" }
        : {
            source: {
              data,
              media_type: attachment.mimeType as "image/png",
              type: "base64"
            },
            type: "image"
          }
    )
  }
  return blocks
}
