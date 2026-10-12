import type { CallToolResult, Tool } from "@modelcontextprotocol/sdk/types.js"

/// An app Computer Use drove, as its observations name it.
export interface ComputerUseApp {
  readonly bundleId: string
  readonly name?: string
  readonly path?: string
}

export interface AutomationProviderContext {
  readonly sessionId: string
  readonly projectId?: string | undefined
  readonly agentLabel?: string | undefined
  /** Reuses gateway validation and artifact persistence for nested browser cells. */
  readonly invokeBrowser?: (name: string, args: Record<string, unknown>) => Promise<unknown>
  /** Hears the app each Computer Use observation resolved, nested REPL calls included. */
  readonly onApp?: (app: ComputerUseApp) => void
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

/// The page a Browser Use result says its call left the tab on: page
/// actions (navigation, back/forward, reload, clicks) lead with a
/// `Page URL:` line.
export const browserResultPageUrl = (result: CallToolResult): string | undefined => {
  const first = result.content[0]
  if (result.isError === true || first?.type !== "text") return undefined
  return /^Page URL: (\S+)/.exec(first.text)?.[1]
}

/// The app a Computer Use observation resolved (`resolvedApp`). Actions and
/// listings name none.
export const computerResultApp = (result: CallToolResult): ComputerUseApp | undefined => {
  const first = result.content[0]
  if (result.isError === true || first?.type !== "text" || !first.text.includes('"resolvedApp"'))
    return undefined
  let app: Readonly<Record<string, unknown>> | undefined
  try {
    app = (JSON.parse(first.text) as { readonly resolvedApp?: Record<string, unknown> }).resolvedApp
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
