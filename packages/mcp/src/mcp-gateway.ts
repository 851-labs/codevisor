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
import type { CallToolResult, Tool } from "@modelcontextprotocol/sdk/types.js"
import { randomUUID } from "node:crypto"
import { realpathSync, statSync } from "node:fs"
import { isAbsolute, relative, resolve } from "node:path"
import { z } from "zod"
import type { McpManagerConfig } from "./mcp-manager.js"
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
  readonly searchTool: RegisteredTool
  readonly runCodeTool: RegisteredTool
}

export interface GatewayRuntime {
  readonly sessionId: string
  readonly projectId?: string | undefined
  /// Live connections keyed by MCP session id (assigned at initialize).
  readonly connections: Map<string, GatewayConnection>
  inventory: string
}

export interface CatalogServer {
  readonly id: string
  readonly name: string
}

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

  const integrationInventory = async (projectId?: string, sessionId?: string): Promise<string> => {
    const names = [
      "Codevisor",
      ...(await run(config.db.resolveMcpServers(projectId, sessionId)))
        .filter((server) => server.enabled)
        .map((server) => server.name.trim())
        .filter((name) => name.length > 0)
    ].sort((left, right) => left.localeCompare(right))
    if (names.length === 0) return "Available integrations: none."
    return ["Available integrations through Codevisor:", ...names.map((name) => `- ${name}`)].join(
      "\n"
    )
  }

  const searchToolDescription = (inventory: string): string =>
    [
      "Compatibility discovery endpoint for integrations connected through Codevisor. Prefer run_code for normal work so discovery, schema inspection, and actions can be composed in one invocation. Use this direct wrapper only when the harness cannot run code.",
      inventory
    ].join("\n\n")

  const runCodeToolDescription = (inventory: string): string =>
    [
      "Primary Codevisor tool interface. Run sandboxed JavaScript or TypeScript that discovers and composes enabled integration, Browser Use, and Computer Use tools. Prefer this over direct search/describe/execute calls. The isolate has no filesystem, network, process environment, or credentials.",
      'Inside code, start with `await tools.search({ query: "<intent>" })`, inspect a match with `await tools.describe.tool({ path })`, then call the exact returned path with `await tools[path](args)`. Pass an async arrow function.',
      inventory
    ].join("\n\n")

  const refreshGatewayInventories = async (): Promise<void> => {
    await Promise.all(
      [...gateways.values()].map(async (gateway) => {
        const inventory = await integrationInventory(gateway.projectId, gateway.sessionId)
        if (inventory === gateway.inventory) return
        gateway.inventory = inventory
        for (const connection of gateway.connections.values()) {
          connection.searchTool.update({ description: searchToolDescription(inventory) })
          connection.runCodeTool.update({ description: runCodeToolDescription(inventory) })
        }
      })
    )
  }

  const allTools = async (
    projectId?: string,
    sessionId?: string
  ): Promise<ReadonlyArray<{ server: CatalogServer; tool: Tool }>> => {
    const enabled = (await run(config.db.resolveMcpServers(projectId, sessionId))).filter(
      (server) => server.enabled
    )
    const results = await Promise.allSettled(
      enabled.map(async (server) => {
        const provider = automationProviders.get(server.id)
        return provider === undefined
          ? { server, tools: (await connectUpstream(server.id)).tools }
          : { server, tools: provider.tools }
      })
    )
    return [
      ...codevisorProvider.tools.map((tool) => ({
        server: { id: "codevisor", name: "Codevisor" },
        tool
      })),
      ...results.flatMap((result) =>
        result.status === "fulfilled"
          ? result.value.tools.map((tool) => ({ server: result.value.server, tool }))
          : []
      )
    ]
  }

  const gatewayServerAllowed = async (
    serverId: string,
    projectId?: string,
    sessionId?: string
  ): Promise<boolean> =>
    serverId === "codevisor" ||
    (await run(config.db.resolveMcpServers(projectId, sessionId))).some(
      (candidate) => candidate.id === serverId && candidate.enabled
    )

  const searchCatalog = async (
    projectId: string | undefined,
    sessionId: string,
    query: string,
    limit = 12
  ) => {
    const normalized = query.trim().toLowerCase()
    const terms = normalized.split(/[^a-z0-9]+/).filter((term) => term.length > 1)
    const ranked = (await allTools(projectId, sessionId))
      .map(({ server, tool }) => {
        const serverName = server.name.toLowerCase()
        const toolName = tool.name.toLowerCase()
        const haystack =
          `${server.name} ${tool.name} ${tool.title ?? ""} ${tool.description ?? ""}`.toLowerCase()
        let score = normalized.length > 0 && haystack.includes(normalized) ? 40 : 0
        for (const term of terms) {
          if (serverName.includes(term)) score += 20
          if (toolName.includes(term)) score += 12
          if (haystack.includes(term)) score += 4
        }
        return {
          path: `${server.id}.${tool.name}`,
          server: server.id,
          serverName: server.name,
          name: tool.name,
          title: tool.title,
          description: tool.description,
          score
        }
      })
      .filter((item) => normalized.length === 0 || item.score > 0)
      .sort((left, right) => right.score - left.score || left.path.localeCompare(right.path))
    return {
      items: ranked.slice(0, Math.max(1, Math.min(limit, 50))),
      total: ranked.length,
      workflow:
        "Choose a match, call describe with its server and name, then call execute. Do not stop after discovery when the user asked for an action or answer."
    }
  }

  const describeCatalogPath = async (
    projectId: string | undefined,
    sessionId: string,
    path: string
  ): Promise<Tool> => {
    const separator = path.indexOf(".")
    if (separator <= 0 || separator === path.length - 1)
      throw new Error(`Invalid tool path: ${path}`)
    const serverId = path.slice(0, separator)
    const toolName = path.slice(separator + 1)
    const allowed = await gatewayServerAllowed(serverId, projectId, sessionId)
    if (!allowed) throw new Error("Tool server is disabled for this session")
    const provider = automationProviders.get(serverId)
    const definition = (provider?.tools ?? (await connectUpstream(serverId)).tools).find(
      (candidate) => candidate.name === toolName
    )
    if (definition === undefined) throw new Error(`Tool not found: ${path}`)
    return definition
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
    const searchTool = sdkServer.registerTool(
      "search",
      {
        description: searchToolDescription(inventory),
        inputSchema: {
          query: z.string().default(""),
          limit: z.number().int().min(1).max(50).default(12)
        }
      },
      async ({ query, limit }) => ({
        content: [
          {
            type: "text" as const,
            text: JSON.stringify(await searchCatalog(projectId, sessionId, query, limit))
          }
        ]
      })
    )
    sdkServer.registerTool(
      "describe",
      {
        description:
          "Compatibility wrapper that returns one enabled tool schema. Prefer tools.describe.tool inside run_code.",
        inputSchema: { server: z.string(), tool: z.string() }
      },
      async ({ server, tool }) => {
        const allowed = await gatewayServerAllowed(server, projectId, sessionId)
        if (!allowed) {
          return {
            isError: true,
            content: [{ type: "text" as const, text: "Tool server is disabled for this session" }]
          }
        }
        const provider = automationProviders.get(server)
        const definitions = provider?.tools ?? (await connectUpstream(server)).tools
        const definition = definitions.find((candidate) => candidate.name === tool)
        if (definition === undefined) {
          return { isError: true, content: [{ type: "text" as const, text: "Tool not found" }] }
        }
        return { content: [{ type: "text" as const, text: JSON.stringify(definition) }] }
      }
    )
    sdkServer.registerTool(
      "execute",
      {
        description:
          "Compatibility wrapper that executes one enabled tool. Prefer calling the exact tools[path] inside run_code.",
        inputSchema: {
          server: z.string(),
          tool: z.string(),
          arguments: z.record(z.string(), z.unknown()).default({})
        }
      },
      async ({ server, tool, arguments: args }): Promise<CallToolResult> => {
        const installed = server === "codevisor" ? undefined : await record(server)
        const allowed = await gatewayServerAllowed(server, projectId, sessionId)
        if (installed?.enabled === false || !allowed) {
          return {
            isError: true,
            content: [{ type: "text", text: `${installed?.name ?? "Codevisor"} is disabled` }]
          }
        }
        const provider = automationProviders.get(server)
        if (provider !== undefined) {
          return invokeAutomationProvider(
            provider,
            { sessionId, ...(projectId === undefined ? {} : { projectId }) },
            tool,
            args
          )
        }
        const connection = await connectUpstream(server)
        return (await connection.client.callTool({ name: tool, arguments: args })) as CallToolResult
      }
    )
    const runCodeTool = sdkServer.registerTool(
      "run_code",
      {
        description: runCodeToolDescription(inventory),
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
                  return searchCatalog(
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
                  return describeCatalogPath(projectId, sessionId, input.path)
                }
                const separator = path.indexOf(".")
                if (separator <= 0 || separator === path.length - 1) {
                  throw new Error(`Invalid tool path: ${path}`)
                }
                const serverId = path.slice(0, separator)
                const toolName = path.slice(separator + 1)
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
      searchTool,
      runCodeTool
    }
    await sdkServer.connect(transport as unknown as Transport)
    return connection
  }

  return { allTools, createGatewayConnection, gatewayRuntime, refreshGatewayInventories }
}
