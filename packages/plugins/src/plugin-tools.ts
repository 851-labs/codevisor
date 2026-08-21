import type { InstalledPlugin } from "./plugin-store.js"
import { PluginsError } from "./plugins-error.js"

/// One agent tool an installed plugin declares, flattened across plugins for
/// the MCP gateway catalog. The mcp package consumes this shape through a
/// structural seam (its PluginToolSource) rather than a package dependency.
export interface PluginToolSummary {
  readonly pluginId: string
  readonly name: string
  readonly description: string
  /// The manifest's opaque JSON Schema for the tool's arguments, verbatim.
  readonly inputSchema?: unknown
}

/// Caller-provided context forwarded to the plugin inside the signed
/// X-Codevisor-Context header on tool invocations.
export interface PluginToolInvocationContext {
  readonly workspaceId?: string | undefined
  readonly cwd?: string | undefined
}

export interface InvokePluginToolOptions {
  readonly plugin: InstalledPlugin
  readonly toolName: string
  readonly args: Readonly<Record<string, unknown>>
  readonly context: PluginToolInvocationContext
  /// Manager-owned supervisor hooks, so this module needs no supervisor
  /// handle of its own.
  readonly ensureRunning: () => Promise<number>
  readonly noteSuccess: () => void
  readonly markUnreachable: () => void
  /// Manager-owned context signer (the pane token store's HMAC key).
  readonly signedContextHeaders: (
    payload: Readonly<Record<string, unknown>>
  ) => Record<string, string>
  readonly timeoutMs: number
}

/// The tool invocation path: lazily start the plugin, POST the JSON arguments
/// to the tool's manifest path with signed context headers, and resolve the
/// response body (parsed JSON when the plugin answers with JSON, otherwise
/// the raw text). Failures surface as typed PluginsErrors, never raw fetch
/// rejections.
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
    // Same accounting as the pane proxy: a timeout means the process is
    // alive but hung (no kick); anything else means the port is dead even
    // though the runtime looked alive, so kick the supervisor and let the
    // next invocation relaunch instead of hitting a dead port forever.
    if (cause instanceof Error && cause.name === "TimeoutError") {
      throw new PluginsError(
        "unavailable",
        `Plugin ${plugin.id} tool ${toolName} did not respond within ${timeoutMs}ms`
      )
    }
    options.markUnreachable()
    throw new PluginsError(
      "unavailable",
      /* v8 ignore next -- fetch failures are always Error instances. */
      `Plugin ${plugin.id} tool ${toolName} request failed: ${cause instanceof Error ? cause.message : String(cause)}`
    )
  }
  const text = await response.text()
  // Any response means the process is healthy: reset the crash circuit
  // breaker exactly like a completed pane request.
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
