import { realpathSync, statSync } from "node:fs"
import { isAbsolute, relative, resolve } from "node:path"

import type { AutomationToolProvider, BrowserSetupBroker } from "@codevisor/automation"
import { CodeExecutionToolError } from "@codevisor/automation"
import type { McpServerRecord } from "@codevisor/db"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"

import type { makeGatewayCatalog } from "./mcp-gateway-catalog.js"
import type { GatewayCallContext, GatewayOrigin, McpManagerConfig } from "./mcp-manager-types.js"
import { invokeGatewayPluginTool } from "./mcp-plugin-tools.js"
import type { makeRecordingPublisher } from "./mcp-recording-artifacts.js"
import {
  type SandboxArtifactCollector,
  type SandboxArtifactPersistence,
  sandboxSuccessfulToolResult
} from "./mcp-sandbox-results.js"
import { errorMessage, run, type UpstreamConnection } from "./mcp-support.js"

/// Gateway dispatch, split out of mcp-gateway: one tool call routed to the
/// catalog, a plugin, a built-in automation provider, an upstream MCP
/// server, or (for machine-targeted sandbox calls) another machine.

export interface GatewayInvokeOptions {
  /// Collects artifacts across one execution; a fresh one per call otherwise.
  readonly artifacts?: SandboxArtifactCollector
  readonly signal?: AbortSignal
  /// Fires when the call reaches Browser Use.
  readonly onBrowser?: () => void
}

/// Keeps a tool failure's code and details (machine_unavailable and friends)
/// so the sandbox can rethrow it as a named error class.
export const gatewayToolError = (cause: unknown): CodeExecutionToolError => {
  if (cause instanceof CodeExecutionToolError) return cause
  const { code, details } =
    typeof cause === "object" && cause !== null
      ? (cause as { readonly code?: unknown; readonly details?: unknown })
      : {}
  return new CodeExecutionToolError(errorMessage(cause), {
    ...(typeof code === "string" ? { code } : {}),
    ...(typeof details === "object" && details !== null
      ? { details: details as Readonly<Record<string, unknown>> }
      : {})
  })
}

type GatewayCatalog = ReturnType<typeof makeGatewayCatalog>

export interface GatewayDispatchDeps {
  readonly artifactPersistence: SandboxArtifactPersistence
  readonly automationProviders: Map<string, AutomationToolProvider>
  readonly browserSetupBroker: BrowserSetupBroker
  readonly catalog: Pick<
    GatewayCatalog,
    "describeCatalogPath" | "gatewayServerAllowed" | "searchCatalog"
  >
  readonly config: McpManagerConfig
  readonly connectUpstream: (id: string) => Promise<UpstreamConnection>
  readonly publishRecording: ReturnType<typeof makeRecordingPublisher>
  readonly record: (id: string) => Promise<McpServerRecord>
  readonly selfMachine: { readonly id: string; readonly name: string }
}

export const makeGatewayDispatch = (deps: GatewayDispatchDeps) => {
  const {
    artifactPersistence,
    automationProviders,
    browserSetupBroker,
    catalog: { describeCatalogPath, gatewayServerAllowed, searchCatalog },
    config,
    connectUpstream,
    publishRecording,
    record,
    selfMachine
  } = deps

  /// Invokes one plugin tool, resolving the calling session's cwd so plugins
  /// can scope per-project state.
  const invokePluginTool = async (
    sessionId: string,
    name: string,
    args: Readonly<Record<string, unknown>>
  ): Promise<unknown> => {
    const session = await run(config.db.getSessionSummary(sessionId))
    return invokeGatewayPluginTool(
      config.pluginTools,
      name,
      args,
      session.cwd === undefined ? {} : { cwd: session.cwd }
    )
  }

  const invokeAutomationProvider = async (
    provider: AutomationToolProvider,
    context: { readonly sessionId: string; readonly projectId?: string | undefined },
    toolName: string,
    args: Readonly<Record<string, unknown>>,
    collector?: SandboxArtifactCollector,
    remote?: GatewayOrigin
  ): Promise<CallToolResult> => {
    if (provider.id !== "browser" && provider.id !== "computer" && provider.id !== "codevisor") {
      throw new Error(`Unknown automation provider: ${provider.id}`)
    }
    const definition = provider.tools.find((candidate) => candidate.name === toolName)
    if (definition === undefined) throw new Error(`Unknown ${provider.id} tool: ${toolName}`)
    const schema = definition.inputSchema as { readonly properties?: unknown }
    const properties =
      typeof schema.properties === "object" && schema.properties !== null
        ? (schema.properties as Readonly<Record<string, unknown>>)
        : {}
    const unknownArguments = Object.keys(args).filter((key) => !(key in properties))
    if (unknownArguments.length > 0) {
      throw new Error(
        `${provider.id}.${toolName} does not accept ${unknownArguments.map((key) => `\`${key}\``).join(", ")}`
      )
    }
    const providerContext =
      provider.id === "computer"
        ? {
            ...context,
            agentLabel:
              remote === undefined
                ? (await run(config.db.getSessionSummary(context.sessionId))).title
                : `${remote.sessionTitle ?? "Agent"} (from ${remote.machineName})`,
            publishRecording
          }
        : provider.id === "browser"
          ? {
              ...context,
              invokeBrowser: async (name: string, nested: Record<string, unknown>) =>
                sandboxSuccessfulToolResult(
                  await invokeAutomationProvider(
                    provider,
                    context,
                    name,
                    nested,
                    collector,
                    remote
                  ),
                  collector ?? {
                    content: [],
                    maxItems: 20,
                    maxBytes: 20_000_000,
                    persistence: artifactPersistence
                  },
                  "browser." + name
                )
            }
          : context
    let safeArgs = args
    if (
      provider.id === "browser" &&
      (toolName === "upload_files" || toolName === "playwright.fileChooserSetFiles")
    ) {
      if (remote !== undefined) {
        throw new Error(
          `Browser Use uploads files from a workspace folder on this machine; a call from ${remote.machineName} has none`
        )
      }
      const session = await run(config.db.getSessionSummary(context.sessionId))
      if (session.cwd === undefined) throw new Error("This session has no workspace folder")
      const workspaceRoot = realpathSync(session.cwd)
      const paths = Array.isArray(args.paths) ? args.paths : []
      if (paths.length === 0 || !paths.every((path) => typeof path === "string")) {
        throw new Error(`${toolName} requires one or more workspace file paths`)
      }
      const resolvedPaths = paths.map((path) => {
        const candidate = realpathSync(isAbsolute(path) ? path : resolve(workspaceRoot, path))
        const withinWorkspace = relative(workspaceRoot, candidate)
        if (withinWorkspace.startsWith("..") || isAbsolute(withinWorkspace)) {
          throw new Error("Browser Use can only upload files from the current workspace")
        }
        if (!statSync(candidate).isFile()) throw new Error(`Upload path is not a file: ${path}`)
        return candidate
      })
      safeArgs = { ...args, paths: resolvedPaths }
    }
    if (provider.id === "browser") {
      if (toolName === "use_backend") {
        const requested = safeArgs.backend
        if (requested === "managed" || requested === "extension" || requested === "builtin") {
          await browserSetupBroker.resolveBackend(context.sessionId, requested)
        }
      } else if (toolName !== "backends" && toolName !== "connection_status") {
        await browserSetupBroker.resolveBackend(context.sessionId)
      }
    }
    return provider.invoke(providerContext, toolName, safeArgs)
  }

  const newArtifactCollector = (): SandboxArtifactCollector => ({
    content: [],
    maxItems: 4,
    maxBytes: 10 * 1024 * 1024,
    persistence: artifactPersistence
  })

  const isRemoteOrigin = (origin: GatewayOrigin | undefined): origin is GatewayOrigin =>
    origin !== undefined && origin.machineId !== selfMachine.id

  /// One gateway tool call: catalog search/describe, plugin tools, built-in
  /// automation providers, and upstream MCP servers. Calls whose origin is
  /// another machine run under a synthetic session key so browser tabs and
  /// recordings stay scoped to the calling chat.
  const invokeGatewayTool = async (
    ctx: GatewayCallContext,
    path: string,
    args: unknown,
    options: GatewayInvokeOptions = {}
  ): Promise<unknown> => {
    const remote = isRemoteOrigin(ctx.origin) ? ctx.origin : undefined
    const scopeKey =
      remote === undefined
        ? ctx.sessionId
        : `remote:${remote.machineId}:${remote.sessionId ?? "none"}`
    if (scopeKey === undefined) throw new Error("Gateway calls need a calling session")
    // Session and project settings only exist for chats on this machine.
    const sessionId = remote === undefined ? ctx.sessionId : undefined
    const projectId = remote === undefined ? ctx.projectId : undefined
    const artifacts = options.artifacts ?? newArtifactCollector()
    const input = typeof args === "object" && args !== null ? (args as Record<string, unknown>) : {}
    if (path === "search") {
      return searchCatalog(
        projectId,
        sessionId,
        typeof input.query === "string" ? input.query : "",
        typeof input.limit === "number" ? input.limit : 12
      )
    }
    if (path === "describe.tool") {
      if (typeof input.path !== "string") {
        throw new Error("tools.describe.tool expects { path: string }")
      }
      return describeCatalogPath(projectId, sessionId, input.path)
    }
    const separator = path.indexOf(".")
    if (separator <= 0 || separator === path.length - 1) {
      throw new Error(`Invalid tool path: ${path}`)
    }
    const serverId = path.slice(0, separator)
    const toolName = path.slice(separator + 1)
    if (serverId === "plugin") {
      if (sessionId !== undefined) return invokePluginTool(sessionId, toolName, input)
      try {
        return await invokeGatewayPluginTool(config.pluginTools, toolName, input, {})
      } catch (cause) {
        throw new Error(
          `plugin.${toolName} failed without a workspace folder (called from ${remote?.machineName ?? "another machine"}): ${errorMessage(cause)}`,
          { cause }
        )
      }
    }
    const installed = await record(serverId)
    const allowed = await gatewayServerAllowed(serverId, projectId, sessionId)
    if (!installed.enabled || !allowed) {
      throw new Error(`${installed.name} is disabled for this session`)
    }
    const provider = automationProviders.get(serverId)
    if (provider !== undefined) {
      if (serverId === "browser") options.onBrowser?.()
      return sandboxSuccessfulToolResult(
        await invokeAutomationProvider(
          provider,
          { sessionId: scopeKey, ...(projectId === undefined ? {} : { projectId }) },
          toolName,
          input,
          artifacts,
          remote
        ),
        artifacts,
        path
      )
    }
    const connection = await connectUpstream(serverId)
    return sandboxSuccessfulToolResult(
      (await connection.client.callTool(
        { name: toolName, arguments: input },
        undefined,
        options.signal === undefined ? undefined : { signal: options.signal }
      )) as CallToolResult,
      artifacts,
      path
    )
  }

  const invokeRemoteGatewayCall = (
    origin: GatewayOrigin,
    path: string,
    args: unknown,
    signal?: AbortSignal
  ): Promise<unknown> =>
    invokeGatewayTool({ origin }, path, args, signal === undefined ? {} : { signal })

  /// Sends a sandbox call to another machine through the server's machine
  /// link. Without one, the machine is unreachable before anything is sent.
  const invokeOnMachine = (
    target: { readonly machine: string; readonly machineName?: string },
    path: string,
    args: unknown,
    origin: GatewayOrigin,
    signal: AbortSignal | undefined
  ): Promise<unknown> => {
    const name = target.machineName ?? target.machine
    if (config.remoteInvoker === undefined) {
      throw new CodeExecutionToolError(`${name} is unreachable: this server has no machine link`, {
        code: "machine_unavailable",
        details: { machineId: target.machine, name, phase: "before-send" }
      })
    }
    return config.remoteInvoker(target.machine, path, args, origin, signal)
  }

  return {
    invokeAutomationProvider,
    invokeGatewayTool,
    invokeOnMachine,
    invokeRemoteGatewayCall,
    newArtifactCollector
  }
}
