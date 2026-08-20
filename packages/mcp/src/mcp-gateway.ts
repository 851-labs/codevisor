import type {
  CodeExecutor,
  BrowserSetupBroker,
  AutomationToolProvider
} from "@codevisor/automation"
import { CodeExecutionToolError } from "@codevisor/automation"
import type { McpServerRecord } from "@codevisor/db"
import {
  McpServer as McpSdkServer,
  type RegisteredTool
} from "@modelcontextprotocol/sdk/server/mcp.js"
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { randomUUID } from "node:crypto"
import { realpathSync, statSync } from "node:fs"
import { isAbsolute, relative, resolve } from "node:path"
import { z } from "zod"
import { executeToolDescription, makeGatewayCatalog } from "./mcp-gateway-catalog.js"
import type { McpManagerConfig } from "./mcp-manager.js"
import { invokeGatewayPluginTool } from "./mcp-plugin-tools.js"
import {
  sandboxOutputContent,
  sandboxSuccessfulToolResult,
  type SandboxArtifactCollector
} from "./mcp-sandbox-results.js"
import { errorMessage, run, type UpstreamConnection } from "./mcp-support.js"

/// One live MCP connection to a gateway. Harnesses may connect more than
/// once per Codevisor session: codex 0.145+ tears down and re-initializes
/// its MCP connections on mid-session events (account changes, plugin
/// changes), so a gateway must accept fresh `initialize` handshakes for as
/// long as the session lives — a single stateful transport (the previous
/// design) rejects the redial and the harness silently drops every tool.
export interface GatewayConnection {
  readonly server: McpSdkServer
  readonly transport: StreamableHTTPServerTransport
  readonly executeTool: RegisteredTool
}

export interface GatewayRuntime {
  readonly sessionId: string
  readonly projectId?: string | undefined
  /// Live connections keyed by MCP session id (assigned at initialize).
  readonly connections: Map<string, GatewayConnection>
  inventory: string
}

export type { CatalogServer } from "./mcp-gateway-catalog.js"

export interface ToolGatewayConfig {
  readonly name: string
  readonly url: string
  readonly bearerToken: string
}

export interface McpGatewayDeps {
  readonly automationProviders: Map<string, AutomationToolProvider>
  readonly browserSetupBroker: BrowserSetupBroker
  readonly codeExecutor: CodeExecutor
  readonly codevisorProvider: AutomationToolProvider
  readonly config: McpManagerConfig
  readonly connectUpstream: (id: string) => Promise<UpstreamConnection>
  readonly gateways: Map<string, GatewayRuntime>
  readonly record: (id: string) => Promise<McpServerRecord>
}

export const makeMcpGateway = (deps: McpGatewayDeps) => {
  const {
    automationProviders,
    browserSetupBroker,
    codeExecutor,
    codevisorProvider,
    config,
    connectUpstream,
    gateways,
    record
  } = deps

  const {
    allTools,
    describeCatalogPath,
    gatewayServerAllowed,
    integrationInventory,
    searchCatalog
  } = makeGatewayCatalog({ automationProviders, codevisorProvider, config, connectUpstream })

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

  const refreshGatewayInventories = async (): Promise<void> => {
    await Promise.all(
      [...gateways.values()].map(async (gateway) => {
        const inventory = await integrationInventory(gateway.projectId, gateway.sessionId)
        if (inventory === gateway.inventory) return
        gateway.inventory = inventory
        for (const connection of gateway.connections.values()) {
          connection.executeTool.update({ description: executeToolDescription(inventory) })
        }
      })
    )
  }

  const invokeAutomationProvider = async (
    provider: AutomationToolProvider,
    context: { readonly sessionId: string; readonly projectId?: string | undefined },
    toolName: string,
    args: Readonly<Record<string, unknown>>
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
            agentLabel: (await run(config.db.getSessionSummary(context.sessionId))).title
          }
        : context
    let safeArgs = args
    if (
      provider.id === "browser" &&
      (toolName === "upload_files" || toolName === "playwright.fileChooserSetFiles")
    ) {
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
        if (requested === "managed" || requested === "extension") {
          await browserSetupBroker.resolveBackend(context.sessionId, requested)
        }
      } else if (toolName !== "backends" && toolName !== "connection_status") {
        await browserSetupBroker.resolveBackend(context.sessionId)
      }
    }
    return provider.invoke(providerContext, toolName, safeArgs)
  }

  const gatewayRuntime = async (sessionId: string, projectId?: string): Promise<GatewayRuntime> => {
    const inventory = await integrationInventory(projectId, sessionId)
    return {
      sessionId,
      ...(projectId === undefined ? {} : { projectId }),
      connections: new Map(),
      inventory
    }
  }

  /// Build one MCP server + transport pair for a fresh `initialize`. The
  /// connection registers itself in the runtime once the SDK assigns its MCP
  /// session id, and removes itself when the transport closes.
  const createGatewayConnection = async (runtime: GatewayRuntime): Promise<GatewayConnection> => {
    const { inventory, projectId, sessionId } = runtime
    const sdkServer = new McpSdkServer({ name: "Codevisor Tool Gateway", version: "0.1.0" })
    const executeTool = sdkServer.registerTool(
      "execute",
      {
        description: executeToolDescription(inventory),
        inputSchema: { code: z.string().min(1) }
      },
      async ({ code }, { signal }) => {
        const artifacts: SandboxArtifactCollector = {
          content: [],
          maxItems: 4,
          maxBytes: 10 * 1024 * 1024
        }
        const result = await codeExecutor.execute(
          code,
          {
            invoke: async ({ path, args }) => {
              try {
                if (path === "search") {
                  const input =
                    typeof args === "object" && args !== null
                      ? (args as { query?: unknown; limit?: unknown })
                      : {}
                  return await searchCatalog(
                    projectId,
                    sessionId,
                    typeof input.query === "string" ? input.query : "",
                    typeof input.limit === "number" ? input.limit : 12
                  )
                }
                if (path === "describe.tool") {
                  const input =
                    typeof args === "object" && args !== null ? (args as { path?: unknown }) : {}
                  if (typeof input.path !== "string") {
                    throw new Error("tools.describe.tool expects { path: string }")
                  }
                  return await describeCatalogPath(projectId, sessionId, input.path)
                }
                const separator = path.indexOf(".")
                if (separator <= 0 || separator === path.length - 1) {
                  throw new Error(`Invalid tool path: ${path}`)
                }
                const serverId = path.slice(0, separator)
                const toolName = path.slice(separator + 1)
                if (serverId === "plugin") {
                  return await invokePluginTool(
                    sessionId,
                    toolName,
                    typeof args === "object" && args !== null
                      ? (args as Record<string, unknown>)
                      : {}
                  )
                }
                const installed = serverId === "codevisor" ? undefined : await record(serverId)
                const allowed = await gatewayServerAllowed(serverId, projectId, sessionId)
                if (installed?.enabled === false || !allowed) {
                  throw new Error(`${installed?.name ?? "Codevisor"} is disabled for this session`)
                }
                const toolArgs =
                  typeof args === "object" && args !== null ? (args as Record<string, unknown>) : {}
                const provider = automationProviders.get(serverId)
                if (provider !== undefined) {
                  return sandboxSuccessfulToolResult(
                    await invokeAutomationProvider(
                      provider,
                      { sessionId, ...(projectId === undefined ? {} : { projectId }) },
                      toolName,
                      toolArgs
                    ),
                    artifacts
                  )
                }
                const connection = await connectUpstream(serverId)
                return sandboxSuccessfulToolResult(
                  (await connection.client.callTool({
                    name: toolName,
                    arguments: toolArgs
                  })) as CallToolResult,
                  artifacts
                )
              } catch (cause) {
                throw new CodeExecutionToolError(errorMessage(cause))
              }
            }
          },
          { signal }
        )
        if (result.error !== undefined) {
          return { isError: true, content: [{ type: "text" as const, text: result.error }] }
        }
        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                result: result.result,
                logs: result.logs
              })
            },
            ...sandboxOutputContent(result.output),
            ...artifacts.content
          ]
        }
      }
    )
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: randomUUID,
      onsessioninitialized: (mcpSessionId) => {
        runtime.connections.set(mcpSessionId, connection)
      }
    })
    transport.onclose = () => {
      /* v8 ignore next -- transports without a completed initialize never register. */
      if (transport.sessionId !== undefined) runtime.connections.delete(transport.sessionId)
    }
    const connection: GatewayConnection = {
      server: sdkServer,
      transport,
      executeTool
    }
    await sdkServer.connect(transport as unknown as Transport)
    return connection
  }

  return { allTools, createGatewayConnection, gatewayRuntime, refreshGatewayInventories }
}
