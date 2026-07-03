import type { PromptAttachmentInput } from "./types.js"

/// Media types the Anthropic API accepts as inline base64 image blocks.
export const INLINE_IMAGE_MEDIA_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/gif",
  "image/webp"
])

/// Fallback for attachments a provider cannot embed: the server materializes
/// every attachment to a temp file, and all harnesses can read from disk.
export const attachmentPathNote = (attachment: PromptAttachmentInput): string =>
  `[Attached file: ${attachment.path} (${attachment.name}, ${attachment.mimeType})]`

export const withAttachmentNotes = (
  text: string,
  attachments: ReadonlyArray<PromptAttachmentInput>
): string =>
  attachments.length === 0
    ? text
    : [text, ...attachments.map(attachmentPathNote)].filter((part) => part !== "").join("\n\n")
