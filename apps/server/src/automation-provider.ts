import type { CallToolResult, Tool } from "@modelcontextprotocol/sdk/types.js"

export interface AutomationProviderContext {
  readonly sessionId: string
  readonly projectId?: string | undefined
  readonly agentLabel?: string | undefined
}

export interface AutomationToolProvider {
  readonly id: "browser" | "computer"
  readonly tools: ReadonlyArray<Tool>
  readonly invoke: (
    context: AutomationProviderContext,
    toolName: string,
    args: Readonly<Record<string, unknown>>
  ) => Promise<CallToolResult>
  readonly closeSession: (sessionId: string) => Promise<void>
  readonly close: () => Promise<void>
}

export const textToolResult = (text: string, isError = false): CallToolResult => ({
  ...(isError ? { isError: true } : {}),
  content: [{ type: "text", text }]
})
