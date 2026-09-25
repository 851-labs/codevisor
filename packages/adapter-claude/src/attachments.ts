import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk"
import { withAttachmentNotes, type PromptInput } from "@codevisor/agent-runtime"

export type ClaudeContentBlock = Exclude<SDKUserMessage["message"]["content"], string>[number]

/// Builds the user-message content blocks: inline what the server sized for
/// embedding (images, small PDFs) so the model sees the content, and note EVERY
/// attachment's materialized temp-file path in the text — including inline
/// images — so the agent also knows where each file lives on disk (to copy it
/// into the repo, re-read it, etc.).
export const claudeContent = (input: PromptInput): Array<ClaudeContentBlock> => {
  const attachments = input.attachments ?? []
  const inline = attachments.flatMap((attachment) =>
    attachment.inline === undefined ? [] : [attachment.inline]
  )
  const text = withAttachmentNotes(input.text, attachments)
  const blocks: Array<ClaudeContentBlock> = []
  if (text !== "" || inline.length === 0) {
    blocks.push({ text, type: "text" })
  }
  for (const content of inline) {
    const data = content.data.toString("base64")
    blocks.push(
      content.mimeType === "application/pdf"
        ? { source: { data, media_type: "application/pdf", type: "base64" }, type: "document" }
        : {
            source: {
              data,
              media_type: content.mimeType as "image/png",
              type: "base64"
            },
            type: "image"
          }
    )
  }
  return blocks
}
