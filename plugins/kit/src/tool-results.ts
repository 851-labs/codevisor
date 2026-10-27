import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"

export const jsonResult = (value: unknown): CallToolResult => ({
  content: [{ type: "text", text: JSON.stringify(value, null, 2) }]
})

export const structuredResult = (value: Record<string, unknown>): CallToolResult => ({
  ...jsonResult(value),
  structuredContent: value
})

export const errorResult = (message: string): CallToolResult => ({
  content: [{ type: "text", text: message }],
  isError: true
})
