import { randomUUID } from "node:crypto"

import type { RuntimeEventSink } from "@codevisor/agent-runtime"
import type { FileMetadata } from "@codevisor/api"
import type {
  CodeExecutor,
  BrowserSetupBroker,
  AutomationToolProvider
} from "@codevisor/automation"
import type { McpServerRecord } from "@codevisor/db"
import { makeAttachmentStore } from "@codevisor/db"
import {
  McpServer as McpSdkServer,
  type RegisteredTool
} from "@modelcontextprotocol/sdk/server/mcp.js"
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { z } from "zod"

import { executeToolDescription, makeGatewayCatalog } from "./mcp-gateway-catalog.js"
import { gatewayToolError, makeGatewayDispatch } from "./mcp-gateway-dispatch.js"
import { executionArgsHash, makeExecutionRecorder } from "./mcp-gateway-execution.js"
import type { GatewayCallContext, GatewayOrigin, McpManagerConfig } from "./mcp-manager-types.js"
import { makeRecordingPublisher } from "./mcp-recording-artifacts.js"
import { type SandboxArtifactPersistence, sandboxOutputContent } from "./mcp-sandbox-results.js"
import { run, type UpstreamConnection } from "./mcp-support.js"

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
  /// The session's event sink; executions stream their transcript
  /// annotation through it. Replaced whenever the session re-issues.
  sink?: RuntimeEventSink | undefined
}

export type { CatalogServer } from "./mcp-gateway-catalog.js"

export interface ToolGatewayConfig {
  readonly name: string
  readonly url: string
  readonly bearerToken: string
  /// Standing instructions the harness adds to the agent's system prompt
  /// (mirrors @codevisor/agent-runtime's ToolGatewayConfig).
  readonly instructions?: string
}

export interface McpGatewayDeps {
  readonly automationProviders: Map<string, AutomationToolProvider>
  readonly browserSetupBroker: BrowserSetupBroker
  readonly codeExecutor: CodeExecutor
  readonly config: McpManagerConfig
  readonly connectUpstream: (id: string) => Promise<UpstreamConnection>
  readonly gateways: Map<string, GatewayRuntime>
  readonly isSuppressed: (name: string) => boolean
  readonly record: (id: string) => Promise<McpServerRecord>
  readonly selfMachine: { readonly id: string; readonly name: string }
  /// The client window that sent the session's current turn, if any.
  readonly turnClientId: (sessionId: string) => string | undefined
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
    config,
    connectUpstream,
    gateways,
    isSuppressed,
    record,
    selfMachine,
    turnClientId
  } = deps

  const {
    allTools,
    describeCatalogPath,
    gatewayServerAllowed,
    integrationInventory,
    searchCatalog
  } = makeGatewayCatalog({
    automationProviders,
    config,
    connectUpstream,
    isSuppressed
  })

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

  /// Emitted tool artifacts (screenshots and the like) become immutable server
  /// files so the agent can embed them in its reply and the user can open them.
  const attachmentStore = makeAttachmentStore(config.dataDir)
  const publishRecording = makeRecordingPublisher(config.dataDir, (metadata) =>
    run(config.db.createDiskFile(metadata))
  )
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

  const {
    invokeAutomationProvider,
    invokeGatewayTool,
    invokeOnMachine,
    invokeRemoteGatewayCall,
    newArtifactCollector
  } = makeGatewayDispatch({
    artifactPersistence,
    automationProviders,
    browserSetupBroker,
    catalog: { describeCatalogPath, gatewayServerAllowed, searchCatalog },
    config,
    connectUpstream,
    publishRecording,
    record,
    selfMachine
  })

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
        // The description is a display label; any length is accepted and the
        // transcript shortens it, so a long label never fails the call.
        inputSchema: { description: z.string().min(1), code: z.string().min(1) }
      },
      async ({ code, description }, { signal }) => {
        const recorder = makeExecutionRecorder({
          sink: runtime.sink,
          sessionId,
          argsHash: executionArgsHash({ code, description })
        })
        const artifacts = newArtifactCollector()
        const clientId = turnClientId(sessionId)
        const origin: GatewayOrigin = {
          machineId: selfMachine.id,
          machineName: selfMachine.name,
          sessionId,
          ...(clientId === undefined ? {} : { clientId })
        }
        let titledOrigin: Promise<GatewayOrigin> | undefined
        const remoteOrigin = (): Promise<GatewayOrigin> => {
          titledOrigin ??= run(config.db.getSessionSummary(sessionId)).then(
            (session) => ({ ...origin, sessionTitle: session.title }),
            () => origin
          )
          return titledOrigin
        }
        const callContext: GatewayCallContext = {
          sessionId,
          ...(projectId === undefined ? {} : { projectId }),
          origin
        }
        let usedBrowser = false
        const result = await codeExecutor.execute(
          code,
          {
            invoke: async ({ path, args, target }) => {
              const started = performance.now()
              const machine =
                target?.machine === undefined || target.machine === selfMachine.id
                  ? undefined
                  : {
                      machine: target.machine,
                      ...(target.machineName === undefined
                        ? {}
                        : { machineName: target.machineName })
                    }
              const machineLabel =
                machine === undefined ? {} : { machine: machine.machineName ?? machine.machine }
              try {
                const value =
                  machine === undefined
                    ? await invokeGatewayTool(callContext, path, args, {
                        artifacts,
                        signal,
                        onBrowser: () => {
                          usedBrowser = true
                        }
                      })
                    : await invokeOnMachine(machine, path, args, await remoteOrigin(), signal)
                if (target?.internal !== true)
                  recorder.call({
                    path,
                    ...machineLabel,
                    ok: true,
                    ms: Math.round(performance.now() - started)
                  })
                return value
              } catch (cause) {
                const error = gatewayToolError(cause)
                if (target?.internal !== true)
                  recorder.call({
                    path,
                    ...machineLabel,
                    ok: false,
                    ms: Math.round(performance.now() - started),
                    error: error.message
                  })
                throw error
              }
            }
          },
          {
            signal,
            onStatus: recorder.status,
            context: {
              machine: selfMachine,
              ...(clientId === undefined ? {} : { originClientId: clientId })
            }
          }
        )
        await recorder.finish(result.error)
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
    // oxlint-disable-next-line unicorn/prefer-add-event-listener -- MCP transports expose callback properties, not addEventListener
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

  return {
    allTools,
    createGatewayConnection,
    gatewayRuntime,
    invokeGatewayTool,
    invokeRemoteGatewayCall,
    refreshGatewayInventories
  }
}
