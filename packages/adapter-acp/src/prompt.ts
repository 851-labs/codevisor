import { pathToFileURL } from "node:url"

import type { ContentBlock as AcpContentBlock } from "@agentclientprotocol/sdk"
import type { PromptInput } from "@codevisor/agent-runtime"

export interface AcpPromptCapabilities {
  readonly image?: boolean
}

/* v8 ignore start */
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
