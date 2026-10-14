import { withAttachmentNotes, type PromptInput } from "@codevisor/agent-runtime"

import { mentionedCodexSkills, type CodexSkill } from "./skills.js"

export type CodexInputItem =
  | { readonly text: string; readonly type: "text" }
  | { readonly path: string; readonly type: "localImage" }
  | { readonly name: string; readonly path: string; readonly type: "skill" }

export const codexInput = (
  input: PromptInput,
  skills: ReadonlyArray<CodexSkill> = []
): Array<CodexInputItem> => {
  const attachments = input.attachments ?? []
  const images = attachments.filter((attachment) => attachment.kind === "image")
  const files = attachments.filter((attachment) => attachment.kind !== "image")
  const text = withAttachmentNotes(input.text, files)
  const items: Array<CodexInputItem> = []
  if (text !== "" || images.length === 0) {
    items.push({ text, type: "text" })
  }
  for (const image of images) {
    items.push({ path: image.path, type: "localImage" })
  }
  for (const skill of mentionedCodexSkills(input.text, skills)) {
    items.push({ name: skill.name, path: skill.path, type: "skill" })
  }
  return items
}
