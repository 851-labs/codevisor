import type { AttachmentRef } from "@codevisor/api"
import type { OpenAssistantText } from "@codevisor/db"

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
  await captureAssistantTexts(
    services,
    fanout,
    serverId,
    sessionId,
    await run(services.db.listOpenAssistantTexts(sessionId))
  )
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
  if (attachments.length === 0) return false
  await appendAndPublish(services.db, fanout, "session.output", sessionId, {
    sessionUpdate: "assistant_message_finalized",
    markdown: item.text,
    ...(item.messageId === undefined ? {} : { messageId: item.messageId }),
    attachments,
    serverId
  })
  return true
}

export const withClosedTextCapture = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  apply: () => Promise<void>
): Promise<void> => {
  const before = await run(services.db.listOpenAssistantTexts(sessionId))
  await apply()
  if (before.length === 0) return

  const after = await run(services.db.listOpenAssistantTexts(sessionId))
  const closed = before.filter((text) => !after.some((open) => sameText(open, text)))
  await captureAssistantTexts(services, fanout, serverId, sessionId, closed)
}

const captureAssistantTexts = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  texts: ReadonlyArray<OpenAssistantText>
): Promise<void> => {
  if (texts.length === 0) return

  const { cwd } = await run(services.db.getSessionSummary(sessionId))
  for (const text of texts) {
    const source = await run(services.db.readAssistantText(text.itemId, text.entryKey))
    const existing = await itemAttachments(services, sessionId, text.itemId)
    const captured = await captureMarkdownFiles(services, source, cwd, existing)
    if (captured.markdown === source) continue
    await appendAndPublish(services.db, fanout, "session.output", sessionId, {
      sessionUpdate: "assistant_text_rewritten",
      itemId: text.itemId,
      entryKey: text.entryKey,
      markdown: captured.markdown,
      attachments: captured.attachments.filter((file) => captured.markdown.includes(file.fileId)),
      serverId
    })
  }
}

const itemAttachments = async (
  services: CodevisorServerServices,
  sessionId: string,
  itemId: string
): Promise<ReadonlyArray<AttachmentRef>> => {
  const page = await run(services.db.getTranscriptPage(sessionId, undefined, 8))
  return page.items.find((item) => item.id === itemId)?.attachments ?? []
}

const sameText = (left: OpenAssistantText, right: OpenAssistantText): boolean =>
  left.itemId === right.itemId && left.entryKey === right.entryKey

export interface CapturedMarkdown {
  readonly markdown: string
  readonly attachments: ReadonlyArray<AttachmentRef>
}

export const captureMarkdownFiles = async (
  services: CodevisorServerServices,
  source: string,
  cwd: string | undefined,
  existing: ReadonlyArray<AttachmentRef>
): Promise<CapturedMarkdown> => {
  const attachments = [...existing]
  let markdown = source
  for (const reference of [...markdownFileReferences(source)].toReversed()) {
    if (!shouldCaptureFile(reference)) continue
    const path = localArtifactPath(reference.target, cwd)
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
  return { markdown, attachments }
}
