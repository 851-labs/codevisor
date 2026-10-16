import type { CallToolResult, Tool } from "@modelcontextprotocol/sdk/types.js"

import { recordOrEmpty, recordOrUndefined, type UnknownRecord } from "./unknown-values.js"

export interface ComputerUseApp {
  readonly bundleId: string
  readonly name?: string
  readonly path?: string
}

export interface AutomationProviderContext {
  readonly sessionId: string
  readonly projectId?: string | undefined
  readonly agentLabel?: string | undefined
  readonly signal?: AbortSignal | undefined
  readonly deadline?: number | undefined
  readonly invokeBrowser?: (name: string, args: Record<string, unknown>) => Promise<unknown>
  readonly onApp?: (app: ComputerUseApp) => void
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

export const browserResultPageUrl = (result: CallToolResult): string | undefined => {
  const first = result.content[0]
  if (result.isError === true || first?.type !== "text") return undefined
  return /^Page URL: (\S+)/.exec(first.text)?.[1]
}

export const computerResultApp = (result: CallToolResult): ComputerUseApp | undefined => {
  const first = result.content[0]
  if (result.isError === true || first?.type !== "text" || !first.text.includes('"resolvedApp"'))
    return undefined
  let app: UnknownRecord | undefined
  try {
    app = recordOrUndefined(recordOrEmpty(JSON.parse(first.text)).resolvedApp)
  } catch {
    return undefined
  }
  if (typeof app?.id !== "string" || app.id === "") return undefined
  return {
    bundleId: app.id,
    ...(typeof app.name === "string" ? { name: app.name } : {}),
    ...(typeof app.path === "string" ? { path: app.path } : {})
  }
}
