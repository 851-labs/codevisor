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
import { z } from "zod"

import { executeToolDescription, makeGatewayCatalog } from "./mcp-gateway-catalog.js"
import { makeGatewayDispatch } from "./mcp-gateway-dispatch.js"
import { makeExecuteHandler } from "./mcp-gateway-execute.js"
import {
  EXECUTE_DEFAULT_TIMEOUT_MS,
  EXECUTE_MAX_TIMEOUT_MS,
  reportSkillRead
} from "./mcp-gateway-execution.js"
import type { ExecutionJobs } from "./mcp-gateway-jobs.js"
import {
  composerSkills,
  DESCRIPTION_GUIDANCE,
  skillsToolDescription,
  skillsToolResult
} from "./mcp-gateway-skills.js"
import type { McpManagerConfig } from "./mcp-manager-types.js"
import type { PluginAppViewStore } from "./mcp-plugin-app-views.js"
import { makeRecordingPublisher } from "./mcp-recording-artifacts.js"
import type { SandboxArtifactPersistence } from "./mcp-sandbox-results.js"
import { run, sdkTransport, type UpstreamConnection } from "./mcp-support.js"

export interface GatewayConnection {
  readonly server: McpSdkServer
  readonly transport: StreamableHTTPServerTransport
  readonly executeTool: RegisteredTool
  readonly skillsTool: RegisteredTool
}

export interface GatewayRuntime {
  readonly sessionId: string
  readonly projectId?: string | undefined
  readonly connections: Map<string, GatewayConnection>
  inventory: string
  skillsDescription: string
  sink?: RuntimeEventSink | undefined
}

export type { CatalogServer } from "./mcp-gateway-catalog.js"

export interface ToolGatewayConfig {
  readonly name: string
  readonly url: string
  readonly bearerToken: string
}

export interface McpGatewayDeps {
  readonly appViews: PluginAppViewStore
  readonly automationProviders: Map<string, AutomationToolProvider>
  readonly browserSetupBroker: BrowserSetupBroker
  readonly codeExecutor: CodeExecutor
  readonly config: McpManagerConfig
  readonly connectUpstream: (id: string) => Promise<UpstreamConnection>
  readonly gateways: Map<string, GatewayRuntime>
  readonly isSuppressed: (name: string) => boolean
  readonly jobs: ExecutionJobs
  readonly record: (id: string) => Promise<McpServerRecord>
  readonly selfMachine: { readonly id: string; readonly name: string }
  readonly turnClientId: (sessionId: string) => string | undefined
}

export interface BrowserSessionTab {
  readonly id: string
  readonly url?: string
  readonly origin?: string
}

const BrowserSessionTabsSchema = z.object({
  tabs: z
    .array(
      z.object({
        id: z.string(),
        url: z.string().exactOptional(),
        origin: z.string().exactOptional()
      })
    )
    .optional()
})

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
    appViews,
    automationProviders,
    browserSetupBroker,
    codeExecutor,
    config,
    connectUpstream,
    gateways,
    isSuppressed,
    jobs,
    record,
    selfMachine,
    turnClientId
  } = deps

  const {
    allTools,
    describeCatalogPath,
    gatewayServerAllowed,
    integrationInventory,
    searchCatalog,
    sessionSkills
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
        const skillsDescription = skillsToolDescription(
          await sessionSkills(gateway.projectId, gateway.sessionId)
        )
        const inventoryChanged = inventory !== gateway.inventory
        const skillsChanged = skillsDescription !== gateway.skillsDescription
        gateway.inventory = inventory
        gateway.skillsDescription = skillsDescription
        for (const connection of gateway.connections.values()) {
          if (inventoryChanged) {
            connection.executeTool.update({ description: executeToolDescription(inventory) })
          }
          if (skillsChanged) connection.skillsTool.update({ description: skillsDescription })
        }
      })
    )
  }

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
    finishRemoteBrowserTurn,
    invokeAutomationProvider,
    invokeGatewayTool,
    invokeOnMachine,
    invokeRemoteGatewayCall,
    newArtifactCollector
  } = makeGatewayDispatch({
    appViews,
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
    const parsed = BrowserSessionTabsSchema.parse(JSON.parse(block.text))
    return browserSessionTabsNotice(parsed.tabs ?? [])
  }

  const executeHandler = makeExecuteHandler({
    automationProviders,
    codeExecutor,
    config,
    connectUpstream,
    dispatch: { invokeGatewayTool, invokeOnMachine, newArtifactCollector },
    jobs,
    openBrowserSessionTabs,
    record,
    selfMachine,
    turnClientId
  })

  const gatewayRuntime = async (sessionId: string, projectId?: string): Promise<GatewayRuntime> => {
    const inventory = await integrationInventory(projectId, sessionId)
    const skillsDescription = skillsToolDescription(await sessionSkills(projectId, sessionId))
    return {
      sessionId,
      ...(projectId === undefined ? {} : { projectId }),
      connections: new Map(),
      inventory,
      skillsDescription
    }
  }

  const createGatewayConnection = async (runtime: GatewayRuntime): Promise<GatewayConnection> => {
    const { inventory, projectId, sessionId } = runtime
    const sdkServer = new McpSdkServer({ name: "Codevisor Tool Gateway", version: "0.1.0" })
    const executeTool = sdkServer.registerTool(
      "execute",
      {
        description: executeToolDescription(inventory),
        inputSchema: {
          description: z.string().min(1).describe(DESCRIPTION_GUIDANCE),
          code: z.string().min(1),
          timeout_ms: z
            .number()
            .int()
            .min(1_000)
            .max(EXECUTE_MAX_TIMEOUT_MS)
            .optional()
            .describe(
              `How long to wait for the result, in milliseconds; default ${EXECUTE_DEFAULT_TIMEOUT_MS}. Work still running then keeps going in the background and the call returns a job handle instead of failing.`
            )
        }
      },
      executeHandler(runtime)
    )
    const skillsTool = sdkServer.registerTool(
      "skills",
      {
        description: runtime.skillsDescription,
        annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
        inputSchema: {
          name: z
            .string()
            .optional()
            .describe(
              'A skill name from this tool\'s description, e.g. "execute". Omit to list every skill.'
            ),
          file: z
            .string()
            .optional()
            .describe(
              "A supporting file of a plugin skill, by the path its instructions list, e.g. references/checklist.md. Needs name."
            )
        }
      },
      async ({ name, file }) => {
        const result = await skillsToolResult(await sessionSkills(projectId, sessionId), name, file)
        await reportSkillRead(runtime.sink, sessionId, {
          ...(name === undefined || name.trim() === "" ? {} : { name: name.trim() }),
          ok: !result.isError
        })
        return {
          ...(result.isError ? { isError: true } : {}),
          content: [{ type: "text" as const, text: result.text }]
        }
      }
    )
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: randomUUID,
      onsessioninitialized: (mcpSessionId) => {
        runtime.connections.set(mcpSessionId, connection)
      }
    })
    // oxlint-disable-next-line unicorn/prefer-add-event-listener
    transport.onclose = () => {
      /* v8 ignore next */
      if (transport.sessionId !== undefined) runtime.connections.delete(transport.sessionId)
    }
    const connection: GatewayConnection = {
      server: sdkServer,
      transport,
      executeTool,
      skillsTool
    }
    await sdkServer.connect(sdkTransport(transport))
    return connection
  }

  return {
    allTools,
    composerSkillsFor: async (projectId?: string, sessionId?: string) =>
      composerSkills(await sessionSkills(projectId, sessionId)),
    createGatewayConnection,
    finishRemoteBrowserTurn,
    gatewayRuntime,
    invokeGatewayTool,
    invokeRemoteGatewayCall,
    refreshGatewayInventories
  }
}
