import type { CallToolResult, ContentBlock } from "@modelcontextprotocol/sdk/types.js"

import { CodeExecutionToolError, makePersistentCodeExecutor } from "./code-executor.js"
import { buildComputerUseReplSource } from "./computer-use-repl-source.js"
import { contentBlock, outputContentBlocks } from "./mcp-content.js"
import { recordOrEmpty } from "./unknown-values.js"

export const makeComputerUseRepls = () => {
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
      invoke: (name: string, args: Readonly<Record<string, unknown>>) => Promise<CallToolResult>
    ): Promise<CallToolResult> => {
      let session = sessions.get(id)
      if (!session) {
        session = makePersistentCodeExecutor(buildComputerUseReplSource)
        sessions.set(id, session)
      }
      const result = await session.execute(code, {
        invoke: async ({ path, args }) => {
          const name = path.startsWith("computer.") ? path.slice("computer.".length) : ""
          if (!name || name === "js" || name === "reset")
            throw new CodeExecutionToolError(
              "Only Computer Use actions and observations are available in this REPL"
            )
          const response = await invoke(name, recordOrEmpty(args))
          const message = response.content
            .filter((c) => c.type === "text")
            .map((c) => c.text)
            .join("\n")
          if (response.isError) throw new CodeExecutionToolError(message)
          const value: unknown = message ? JSON.parse(message) : undefined
          const image = response.content.find((c) => c.type === "image")
          return image && value && typeof value === "object" ? { ...value, image } : value
        }
      })
      const content: ContentBlock[] = outputContentBlocks(result.output)
      if (result.error)
        content.unshift({
          type: "text",
          text: result.error.split("\n")[0]!.replace(/^(?:Error: )+/, "")
        })
      else if (result.result !== undefined && result.result !== null) {
        const value = result.result
        if (typeof value === "object" && "image" in value) {
          const { image, ...state } = value
          content.push({ type: "text", text: JSON.stringify(state) })
          const block = contentBlock(image)
          if (block !== undefined) content.push(block)
        } else
          content.push({
            type: "text",
            text: typeof value === "string" ? value : JSON.stringify(value)
          })
      }
      return { ...(result.error ? { isError: true } : {}), content }
    }
  }
}
