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
import type { FileMetadata } from "@codevisor/api"
import { makeAttachmentStore } from "@codevisor/db"
import { executeToolDescription, makeGatewayCatalog } from "./mcp-gateway-catalog.js"
import type { McpManagerConfig } from "./mcp-manager-types.js"
import { invokeGatewayPluginTool } from "./mcp-plugin-tools.js"
import {
  type SandboxArtifactCollector,
  type SandboxArtifactPersistence,
  sandboxOutputContent,
  sandboxSuccessfulToolResult
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
  readonly isSuppressed: (name: string) => boolean
  readonly record: (id: string) => Promise<McpServerRecord>
}

export interface BrowserSessionTab {
  readonly id: string
  readonly url?: string
  readonly origin?: string
}

/** Appended to a failed `execute` result so the retry reuses still-open agent-created tabs. */
export const browserSessionTabsNotice = (tabs: ReadonlyArray<BrowserSessionTab>): string => {
  const created = tabs.filter((tab) => tab.origin === "created")
  if (created.length === 0) return ""
  return (
    "\n\nBrowser Use tabs this session opened are still open. Reuse one with " +
    "browser.tabs.get(id) instead of calling browser.tabs.new() again:\n" +
    created.map((tab) => `- ${tab.id} ${tab.url ?? ""}`.trimEnd()).join("\n")
  )
}

const ARTIFACT_EXTENSIONS: Readonly<Record<string, string>> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/gif": "gif",
  "image/webp": "webp",
  "image/svg+xml": "svg",
  "video/mp4": "mp4",
  "video/quicktime": "mov",
  "video/webm": "webm",
  "audio/mp4": "m4a",
  "application/pdf": "pdf",
  "audio/wav": "wav",
  "audio/mpeg": "mp3",
  "text/plain": "txt",
  "application/json": "json"
}

/// `browser.screenshot` + `image/png` → `browser-screenshot.png`.
export const artifactFileName = (toolPath: string, mimeType: string): string => {
  const base = toolPath
    .replace(/[^a-z0-9]+/gi, "-")
    .replace(/^-+|-+$/g, "")
    .toLowerCase()
  const extension = ARTIFACT_EXTENSIONS[mimeType.split(";")[0]?.trim() ?? ""] ?? "bin"
  return `${base.length === 0 ? "artifact" : base}.${extension}`
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
    isSuppressed,
    record
  } = deps

  const {
    allTools,
    describeCatalogPath,
    gatewayServerAllowed,
    integrationInventory,
    searchCatalog
  } = makeGatewayCatalog({
    automationProviders,
    codevisorProvider,
    config,
    connectUpstream,
    isSuppressed
  })

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

  /// Emitted tool artifacts (screenshots and the like) become immutable server
  /// files so the agent can embed them in its reply and the user can open them.
  const attachmentStore = makeAttachmentStore(config.dataDir)
  const artifactPersistence: SandboxArtifactPersistence = {
    persist: async ({ data, mimeType, toolPath }) => {
      const stored = await attachmentStore.put(data)
      const metadata: FileMetadata = {
        id: randomUUID(),
        name: artifactFileName(toolPath, mimeType),
        mimeType,
        sizeBytes: stored.sizeBytes,
        sha256: stored.sha256,
        kind: mimeType.startsWith("image/") ? "image" : "file",
        createdAt: new Date().toISOString()
      }
      await run(config.db.createDiskFile(metadata))
      return {
        path: await attachmentStore.materialize(metadata),
        fileId: metadata.id,
        name: metadata.name,
        mimeType: metadata.mimeType,
        sizeBytes: metadata.sizeBytes,
        kind: metadata.kind
      }
    }
  }

  /// A failed script leaves whatever tabs it opened behind. Tell the agent about them so the
  /// retry reuses those tabs instead of opening duplicates.
  const openBrowserSessionTabs = async (
    sessionId: string,
    projectId: string | undefined
  ): Promise<string> => {
    const provider = automationProviders.get("browser")
    if (provider === undefined) return ""
    const listed = await invokeAutomationProvider(
      provider,
      { sessionId, ...(projectId === undefined ? {} : { projectId }) },
      "tabs",
      { action: "list", scope: "session" }
    )
    const block = listed.content.find((entry) => entry.type === "text")
    if (listed.isError === true || block?.type !== "text") return ""
    const parsed = JSON.parse(block.text) as { tabs?: ReadonlyArray<BrowserSessionTab> }
    return browserSessionTabsNotice(parsed.tabs ?? [])
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
          maxBytes: 10 * 1024 * 1024,
          persistence: artifactPersistence
        }
        let usedBrowser = false
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
                  if (serverId === "browser") usedBrowser = true
                  return await sandboxSuccessfulToolResult(
                    await invokeAutomationProvider(
                      provider,
                      { sessionId, ...(projectId === undefined ? {} : { projectId }) },
                      toolName,
                      toolArgs
                    ),
                    artifacts,
                    path
                  )
                }
                const connection = await connectUpstream(serverId)
                return await sandboxSuccessfulToolResult(
                  (await connection.client.callTool({
                    name: toolName,
                    arguments: toolArgs
                  })) as CallToolResult,
                  artifacts,
                  path
                )
              } catch (cause) {
                throw new CodeExecutionToolError(errorMessage(cause))
              }
            }
          },
          { signal }
        )
        if (result.error !== undefined) {
          const openTabs = usedBrowser
            ? await openBrowserSessionTabs(sessionId, projectId).catch(() => "")
            : ""
          return {
            isError: true,
            content: [{ type: "text" as const, text: `${result.error}${openTabs}` }]
          }
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
