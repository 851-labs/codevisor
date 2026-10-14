import type { PromptAttachmentInput } from "./types.js"

export const INLINE_IMAGE_MEDIA_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/gif",
  "image/webp"
])

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
