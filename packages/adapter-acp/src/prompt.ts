import { pathToFileURL } from "node:url"

import type { ContentBlock as AcpContentBlock } from "@agentclientprotocol/sdk"
import type { PromptInput } from "@codevisor/agent-runtime"

export interface AcpPromptCapabilities {
  readonly image?: boolean
}

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
/// Builds the session/prompt content blocks. Every attachment is surfaced as a
/// `resource_link` — the ACP baseline that all agents must support — pointing
/// at its materialized temp file, so any harness (opencode included) can read
/// it from disk. Images are ALSO embedded inline as base64 (as the server sized them) when
/// the harness declared image support, so multimodal agents see the pixels directly.
/// Exported for unit tests — the live wiring runs inside the stdio SDK connection.
export const acpPrompt = (
  input: PromptInput,
  capabilities: AcpPromptCapabilities
): Array<AcpContentBlock> => {
  const attachments = input.attachments ?? []
  const blocks: Array<AcpContentBlock> = []
  if (input.text !== "" || attachments.length === 0) {
    blocks.push({ text: input.text, type: "text" })
  }
  for (const attachment of attachments) {
    blocks.push({
      mimeType: attachment.mimeType,
      name: attachment.name,
      size: attachment.sizeBytes,
      type: "resource_link",
      uri: pathToFileURL(attachment.path).href
    })
    const inline = attachment.inline
    if (inline?.mimeType.startsWith("image/") === true && capabilities.image === true) {
      blocks.push({
        data: inline.data.toString("base64"),
        mimeType: inline.mimeType,
        type: "image"
      })
    }
  }
  return blocks
}
/* v8 ignore stop */
