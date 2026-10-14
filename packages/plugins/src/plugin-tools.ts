import type { InstalledPlugin } from "./plugin-store.js"
import { PluginsError } from "./plugins-error.js"

export interface PluginToolSummary {
  readonly pluginId: string
  readonly name: string
  readonly description: string
  readonly inputSchema?: unknown
}

export interface PluginToolInvocationContext {
  readonly workspaceId?: string | undefined
  readonly cwd?: string | undefined
}

export interface InvokePluginToolOptions {
  readonly plugin: InstalledPlugin
  readonly toolName: string
  readonly args: Readonly<Record<string, unknown>>
  readonly context: PluginToolInvocationContext
  readonly ensureRunning: () => Promise<number>
  readonly noteSuccess: () => void
  readonly markUnreachable: () => void
  readonly signedContextHeaders: (
    payload: Readonly<Record<string, unknown>>
  ) => Record<string, string>
  readonly timeoutMs: number
}

export const invokePluginTool = async (options: InvokePluginToolOptions): Promise<unknown> => {
  const { args, context, plugin, timeoutMs, toolName } = options
  const tool = (plugin.manifest.tools ?? []).find((candidate) => candidate.name === toolName)
  if (tool === undefined) {
    throw new PluginsError("notFound", `Plugin ${plugin.id} has no tool: ${toolName}`)
  }
  const port = await options.ensureRunning()
  let response: Response
  try {
    response = await fetch(`http://127.0.0.1:${port}${tool.path}`, {
      body: JSON.stringify(args),
      headers: {
        "content-type": "application/json",
        ...options.signedContextHeaders({
          cwd: context.cwd,
          pluginId: plugin.id,
          toolName,
          workspaceId: context.workspaceId
        })
      },
      method: "POST",
      signal: AbortSignal.timeout(timeoutMs)
    })
  } catch (cause) {
    if (cause instanceof Error && cause.name === "TimeoutError") {
      throw new PluginsError(
        "unavailable",
        `Plugin ${plugin.id} tool ${toolName} did not respond within ${timeoutMs}ms`
      )
    }
    options.markUnreachable()
    throw new PluginsError(
      "unavailable",
      /* v8 ignore next */
      `Plugin ${plugin.id} tool ${toolName} request failed: ${cause instanceof Error ? cause.message : String(cause)}`
    )
  }
  const text = await response.text()
  options.noteSuccess()
  if (!response.ok) {
    throw new PluginsError(
      "invalid",
      `Plugin ${plugin.id} tool ${toolName} failed (HTTP ${response.status})${
        text.length === 0 ? "" : `: ${text}`
      }`
    )
  }
  if ((response.headers.get("content-type") ?? "").includes("application/json")) {
    try {
      return JSON.parse(text) as unknown
    } catch {
      throw new PluginsError(
        "invalid",
        `Plugin ${plugin.id} tool ${toolName} returned invalid JSON`
      )
    }
  }
  return text
}
