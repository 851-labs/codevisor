import type { AttachmentRef } from "@codevisor/api"

import {
  appendAndPublish,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { attachmentRef, captureAssistantFile } from "./assistant-files.js"
import {
  localArtifactPath,
  markdownFileReferences,
  shouldCaptureFile
} from "./markdown-artifacts.js"

export const ATTACHMENT_URL_ORIGIN = "https://attachments.codevisor.invalid/"

const referencePattern = /https:\/\/attachments\.codevisor\.invalid\/([A-Za-z0-9._-]+)/g

export const referencedAttachmentIds = (markdown: string): ReadonlyArray<string> => {
  const ids: Array<string> = []
  for (const match of markdown.matchAll(referencePattern)) {
    const id = match[1]
    if (id !== undefined && !ids.includes(id)) ids.push(id)
  }
  return ids
}

export const promoteAssistantArtifacts = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string
): Promise<boolean> => {
  const page = await run(services.db.getTranscriptPage(sessionId, undefined, 8))
  const item = [...page.items]
    .toReversed()
    .find((candidate) => candidate.role === "assistant" && candidate.isGenerating)
  if (item === undefined) return false
  const references = markdownFileReferences(item.text)
  const ids = references.flatMap(({ target }) => referencedAttachmentIds(target))
  const attachments: Array<AttachmentRef> = [...(item.attachments ?? [])]
  for (const id of ids) {
    if (attachments.some((file) => file.fileId === id)) continue
    const metadata = await run(services.db.getFileMetadata(id))
    if (metadata === undefined) continue
    attachments.push(attachmentRef(metadata))
  }
  const session = await run(services.db.getSessionSummary(sessionId))
  let markdown = item.text
  for (const reference of [...references].toReversed()) {
    if (!shouldCaptureFile(reference)) continue
    const path = localArtifactPath(reference.target, session.cwd)
    if (path === undefined) continue
    try {
      const file = await captureAssistantFile(services, { path }, attachments)
      if (!attachments.some((candidate) => candidate.fileId === file.fileId)) attachments.push(file)
      markdown =
        markdown.slice(0, reference.start) +
        ATTACHMENT_URL_ORIGIN +
        file.fileId +
        (reference.embedded ? "" : "?name=" + encodeURIComponent(file.name)) +
        markdown.slice(reference.end)
    } catch (cause) {
      console.error(
        `Could not preserve assistant file ${path}: ${cause instanceof Error ? cause.message : String(cause)}`
      )
    }
  }
  if (attachments.length === 0) return false
  await appendAndPublish(services.db, fanout, "session.output", sessionId, {
    sessionUpdate: "assistant_message_finalized",
    markdown,
    ...(item.messageId === undefined ? {} : { messageId: item.messageId }),
    attachments,
    serverId
  })
  return true
}
