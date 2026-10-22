import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"

import type { AutomationProviderContext } from "./automation-provider.js"
import { recordOrEmpty, recordOrUndefined, type UnknownRecord } from "./unknown-values.js"

export const makeRecordingArtifacts = () => {
  const published = new Map<
    string,
    ReturnType<NonNullable<AutomationProviderContext["publishRecording"]>>
  >()
  const enrichResult = async (
    result: CallToolResult,
    context: AutomationProviderContext
  ): Promise<CallToolResult> => {
    if (result.isError || !context.publishRecording) return result
    const publish = context.publishRecording
    const enrich = async (value: UnknownRecord): Promise<UnknownRecord> => {
      const file = recordOrUndefined(value.file)
      if (
        value.status !== "stopped" ||
        typeof file?.path !== "string" ||
        typeof file.name !== "string"
      )
        return value
      const key = `${context.sessionId}:${file.path}`
      try {
        let pending = published.get(key)
        if (!pending) {
          pending = publish({ path: file.path, name: file.name })
          published.set(key, pending)
        }
        const attachment = await pending
        return {
          ...value,
          file: { ...file, ...attachment, mimeType: "video/mp4" },
          markdown: `![Recording of the fix](<${attachment.path}>)`,
          showToUser:
            "Embed markdown in your reply to display the video in chat. Read the attaching-files skill (through the `skills` tool) for file delivery."
        }
      } catch (cause) {
        published.delete(key)
        return {
          ...value,
          attachmentError: String(cause),
          next: "The video is saved locally. Call recording_status again to retry creating its chat attachment."
        }
      }
    }
    return {
      ...result,
      content: await Promise.all(
        result.content.map(async (block) => {
          if (block.type !== "text") return block
          const value = recordOrEmpty(JSON.parse(block.text))
          let enriched: Record<string, unknown>
          if (Array.isArray(value.recordings)) {
            enriched = {
              ...value,
              recordings: await Promise.all(
                value.recordings.map((entry) => enrich(recordOrEmpty(entry)))
              )
            }
          } else {
            enriched = await enrich(value)
          }
          return { ...block, text: JSON.stringify(enriched) }
        })
      )
    }
  }
  return {
    enrich: enrichResult,
    closeSession: (id: string) => {
      for (const key of published.keys()) if (key.startsWith(`${id}:`)) published.delete(key)
    },
    clear: () => published.clear()
  }
}
