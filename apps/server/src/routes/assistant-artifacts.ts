import type { AttachmentRef } from "@codevisor/api"
import {
  appendAndPublish,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"

/// Attachment URLs the transcript renderers resolve to server files. Tool
/// artifacts persisted by the MCP gateway are handed to the agent in this
/// form; the agent embeds them to show the user an image.
export const ATTACHMENT_URL_ORIGIN = "https://attachments.codevisor.invalid/"

const referencePattern = /https:\/\/attachments\.codevisor\.invalid\/([A-Za-z0-9._-]+)/g

/// File ids referenced by attachment URLs in Markdown, in order of first appearance.
export const referencedAttachmentIds = (markdown: string): ReadonlyArray<string> => {
  const ids: Array<string> = []
  for (const match of markdown.matchAll(referencePattern)) {
    const id = match[1]
    if (id !== undefined && !ids.includes(id)) ids.push(id)
  }
  return ids
}

/// Just before a turn ends, promote the attachment URLs the assistant embedded
/// into durable attachments on its transcript item by emitting
/// `assistant_message_finalized`. Clients render the referenced files inline;
/// unreferenced artifacts stay private to the agent.
export const promoteAssistantArtifacts = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string
): Promise<boolean> => {
  const page = await run(services.db.getTranscriptPage(sessionId, undefined, 8))
  const item = [...page.items]
    .reverse()
    .find((candidate) => candidate.role === "assistant" && candidate.isGenerating)
  if (item === undefined) return false
  const ids = referencedAttachmentIds(item.text)
  if (ids.length === 0) return false
  const attachments: Array<AttachmentRef> = []
  for (const id of ids) {
    const metadata = await run(services.db.getFileMetadata(id))
    if (metadata === undefined) continue
    attachments.push({
      fileId: metadata.id,
      name: metadata.name,
      mimeType: metadata.mimeType,
      sizeBytes: metadata.sizeBytes,
      kind: metadata.kind
    })
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
