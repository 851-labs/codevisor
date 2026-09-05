import type { CallToolResult, Tool } from "@modelcontextprotocol/sdk/types.js"

export interface AutomationProviderContext {
  readonly sessionId: string
  readonly projectId?: string | undefined
  readonly agentLabel?: string | undefined
  /** Reuses gateway validation and artifact persistence for nested browser cells. */
  readonly invokeBrowser?: (name: string, args: Record<string, unknown>) => Promise<unknown>
  /** Imports a completed native recording into the server's durable attachment store. */
  readonly publishRecording?: (file: { readonly path: string; readonly name: string }) => Promise<{
    readonly fileId: string
    readonly path: string
    readonly sizeBytes: number
  }>
}

export interface AutomationToolProvider {
  readonly id: "browser" | "computer" | "codevisor"
  readonly tools: ReadonlyArray<Tool>
  readonly invoke: (
    context: AutomationProviderContext,
    toolName: string,
    args: Readonly<Record<string, unknown>>
  ) => Promise<CallToolResult>
  readonly finishTurn?: (sessionId: string) => Promise<void>
  readonly closeSession: (sessionId: string) => Promise<void>
  readonly close: () => Promise<void>
}

export const textToolResult = (text: string, isError = false): CallToolResult => ({
  ...(isError ? { isError: true } : {}),
  content: [{ type: "text", text }]
})
