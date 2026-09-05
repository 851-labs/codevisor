import type { CallToolResult, ContentBlock } from "@modelcontextprotocol/sdk/types.js"
import { CodeExecutionToolError, makePersistentCodeExecutor } from "./code-executor.js"
import { buildBrowserReplSource } from "./code-executor-source.js"

export const makeBrowserRepls = () => {
  const sessions = new Map<string, ReturnType<typeof makePersistentCodeExecutor>>()
  const reset = async (id: string) => {
    const session = sessions.get(id)
    sessions.delete(id)
    await session?.close()
  }
  return {
    reset,
    close: async () => {
      await Promise.all([...sessions.keys()].map(reset))
    },
    execute: async (
      id: string,
      code: string,
      invoke: (name: string, args: Record<string, unknown>) => Promise<unknown>
    ): Promise<CallToolResult> => {
      let session = sessions.get(id)
      if (!session) {
        session = makePersistentCodeExecutor(buildBrowserReplSource)
        sessions.set(id, session)
      }
      const result = await session.execute(code, {
        invoke: async ({ path, args }) => {
          const name = path.startsWith("browser.") ? path.slice(8) : ""
          if (!name || name === "js" || name === "reset")
            throw new CodeExecutionToolError(
              "Only browser operations are available inside browser.js"
            )
          try {
            return await invoke(name, (args ?? {}) as Record<string, unknown>)
          } catch (error) {
            throw new CodeExecutionToolError(error instanceof Error ? error.message : String(error))
          }
        }
      })
      const content: ContentBlock[] = (result.output ?? []).flatMap((output) =>
        output && typeof output === "object" && "content" in output
          ? [output.content as ContentBlock]
          : []
      )
      if (result.error) content.push({ type: "text", text: result.error })
      else if (result.result !== undefined)
        content.push({ type: "text", text: JSON.stringify(result.result) })
      return { content, ...(result.error ? { isError: true } : {}) }
    }
  }
}

/** Direct provider users receive the same scalar/object contract without gateway attachments. */
export const browserResultValue = (response: CallToolResult): unknown => {
  const message = response.content
    .filter((c) => c.type === "text")
    .map((c) => c.text)
    .join("\n")
  if (response.isError) throw new Error(message)
  let value: unknown = message
  try {
    value = JSON.parse(message)
  } catch {
    /* Accessibility snapshots are plain text. */
  }
  const image = response.content.find((c) => c.type === "image")
  return image ? { value, image } : value
}
