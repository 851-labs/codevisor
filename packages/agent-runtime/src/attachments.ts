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
/// An inline-eligible attachment that was too large to embed also tells the
/// model so, the way OpenCode reports unreadable parts, so it can read the
/// file from disk or tell the user instead of silently missing it.
export const attachmentPathNote = (attachment: PromptAttachmentInput): string => {
  const note = `[Attached file: ${attachment.path} (${attachment.name}, ${attachment.mimeType})]`
  return attachment.inlineOmitted === true
    ? `${note}\n[${attachment.name} is too large to show inline. Read it from the path above if you need its contents, and tell the user it was not embedded.]`
    : note
}

export const withAttachmentNotes = (
  text: string,
  attachments: ReadonlyArray<PromptAttachmentInput>
): string =>
  attachments.length === 0
    ? text
    : [text, ...attachments.map(attachmentPathNote)].filter((part) => part !== "").join("\n\n")
