import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import type { AutomationProviderContext } from "./automation-provider.js"

/** Keep video bytes outside both JavaScript sandboxes and the MCP transport. */
export const makeRecordingArtifacts = () => {
  const published = new Map<string, Promise<unknown>>()
  const enrichResult = async (
    result: CallToolResult,
    context: AutomationProviderContext
  ): Promise<CallToolResult> => {
    if (result.isError || !context.publishRecording) return result
    const publish = context.publishRecording
    const enrich = async (value: Record<string, unknown>): Promise<Record<string, unknown>> => {
      const file = value.file as { path?: unknown; name?: unknown } | undefined
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
        const attachment = (await pending) as Awaited<ReturnType<typeof publish>>
        return {
          ...value,
          file: { ...file, ...attachment, mimeType: "video/mp4" },
          markdown: `![Recording of the fix](<${attachment.path}>)`,
          showToUser:
            "Embed markdown in your reply to display the video in chat. See the attaching-files skill for file delivery."
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
          const value = JSON.parse(block.text) as Record<string, unknown>
          const enriched = Array.isArray(value.recordings)
            ? { ...value, recordings: await Promise.all(value.recordings.map(enrich)) }
            : await enrich(value)
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
