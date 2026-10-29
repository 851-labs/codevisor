import type { IncomingMessage, ServerResponse } from "node:http"

import type { QuestionAnswer, RuntimeEventSink } from "@codevisor/agent-runtime"
import type {
  BrowserUseConfiguration,
  ComposerSkill,
  CreateMcpServerRequest,
  McpAuthDetection,
  McpServer,
  McpTool,
  UpdateMcpServerRequest
} from "@codevisor/api"
import type {
  AutomationToolProvider,
  BrowserClientPlatform,
  BrowserPreviewSubscription,
  BrowserPreviewViewer,
  BrowserUseProvider
} from "@codevisor/automation"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { CallToolResult, ReadResourceResult } from "@modelcontextprotocol/sdk/types.js"
import type { WebSocket } from "ws"

import type { AutomationTool } from "./mcp-automation-use.js"
import type { ExecutionTimers } from "./mcp-gateway-execution.js"
import type { ExecutionJobs } from "./mcp-gateway-jobs.js"
import type { PackagedSkill, SkillSource } from "./mcp-gateway-skills.js"
import type { ToolGatewayConfig } from "./mcp-gateway.js"
import type { ManagedOAuthClients } from "./mcp-managed-oauth.js"
import type { McpOAuthClock } from "./mcp-oauth-clock.js"
import type { McpCredentialReference, McpOAuthVault } from "./mcp-oauth-grant.js"
import type { PluginAccountSource } from "./mcp-plugin-accounts.js"
import type { PluginAppView } from "./mcp-plugin-apps.js"
import type { PluginConnection } from "./mcp-plugin-connection.js"

export type { AutomationTool } from "./mcp-automation-use.js"
export type { PluginAccountChoice, PluginAccountSource } from "./mcp-plugin-accounts.js"
export type { PluginAppView } from "./mcp-plugin-apps.js"
export type {
  PluginConnection,
  PluginExtensions,
  PluginRequestOptions,
  PluginStreamOptions
} from "./mcp-plugin-connection.js"

export interface GatewayOrigin {
  readonly machineId: string
  readonly machineName: string
  readonly sessionId?: string
  readonly sessionTitle?: string
  readonly clientId?: string
  readonly botId?: string
  readonly botMachineId?: string
}

export interface RemoteGatewayCallOptions {
  readonly signal?: AbortSignal
  readonly remoteParent?: string
}

export interface GatewayCallContext {
  readonly sessionId?: string
  readonly projectId?: string
  readonly origin?: GatewayOrigin
}

export type GatewayRemoteInvoker = (
  machine: string,
  path: string,
  args: unknown,
  origin: GatewayOrigin,
  signal?: AbortSignal
) => Promise<unknown>

export interface McpServerIconSources {
  readonly url?: string
  readonly catalogId?: string
  readonly icons?: ReadonlyArray<{
    readonly src: string
    readonly mimeType?: string | undefined
    readonly sizes?: ReadonlyArray<string> | undefined
    readonly theme?: string | undefined
  }>
  readonly websiteUrl?: string
}

export interface McpManager {
  readonly setBaseUrl: (url: string) => void
  readonly list: () => Promise<ReadonlyArray<McpServer>>
  readonly create: (request: CreateMcpServerRequest) => Promise<McpServer>
  readonly detectAuth: (url: string) => Promise<McpAuthDetection>
  readonly update: (id: string, request: UpdateMcpServerRequest) => Promise<McpServer>
  readonly staticSecrets: (id: string) => Promise<{
    readonly bearerToken?: string
    readonly headers?: Readonly<Record<string, string>>
    readonly env?: Readonly<Record<string, string>>
  }>
  readonly oauthCredential: (id: string) => Promise<McpCredentialReference | null | undefined>
  readonly setOAuthCredential: (
    id: string,
    credential: McpCredentialReference | null
  ) => Promise<void>
  readonly subscribeCredentialsRotated: (listener: (id: string) => void) => () => void
  readonly adoptOAuthOwnership: (legacyOwner: string) => Promise<ReadonlyArray<string>>
  readonly subscribeServersChanged: (listener: (id: string) => void) => () => void
  readonly remove: (id: string) => Promise<void>
  readonly tools: (id?: string) => Promise<ReadonlyArray<McpTool>>
  readonly iconSources: (id: string) => Promise<McpServerIconSources | undefined>
  readonly connect: (id: string) => Promise<McpServer>
  readonly setLocalSuppression: (names: ReadonlySet<string>) => Promise<void>
  readonly beginOAuth: (id: string, redirectBaseUrl?: string) => Promise<string>
  readonly finishOAuth: (state: string, code: string) => Promise<McpServer>
  readonly disconnectOAuth: (id: string) => Promise<McpServer>
  readonly resolved: (projectId?: string, sessionId?: string) => Promise<ReadonlyArray<McpServer>>
  readonly composerSkills: (
    projectId?: string,
    sessionId?: string
  ) => Promise<ReadonlyArray<ComposerSkill>>
  readonly setProjectEnabled: (
    projectId: string,
    serverId: string,
    enabled: boolean
  ) => Promise<ReadonlyArray<McpServer>>
  readonly setSessionEnabled: (
    sessionId: string,
    serverId: string,
    enabled: boolean,
    projectId?: string
  ) => Promise<ReadonlyArray<McpServer>>
  readonly issueGateway: (
    sessionId: string,
    projectId?: string,
    sink?: RuntimeEventSink
  ) => Promise<ToolGatewayConfig>
  readonly answerQuestion: (
    sessionId: string,
    questionId: string,
    answer: QuestionAnswer
  ) => Promise<boolean>
  readonly acceptBrowserExtension: (socket: WebSocket) => void
  readonly acceptBrowserNativeHost: (socket: WebSocket) => void
  readonly acceptBrowserHost: (socket: WebSocket) => void
  readonly subscribeBrowserPreview: (
    sessionId: string,
    viewer: BrowserPreviewViewer
  ) => BrowserPreviewSubscription
  readonly subscribeAutomationUse: (
    sessionId: string,
    listener: (tool: AutomationTool) => void
  ) => () => void
  readonly browserConfiguration: () => Promise<BrowserUseConfiguration>
  readonly openBrowserExtensionInstaller: () => Promise<BrowserUseConfiguration>
  readonly openBrowserExtensionFolder: () => Promise<BrowserUseConfiguration>
  readonly openBrowserExtensionsPage: () => Promise<BrowserUseConfiguration>
  readonly openBrowserExtensionWebStore: () => Promise<BrowserUseConfiguration>
  readonly browserExtensionArchive: () => string
  readonly browserExtensionIcon: () => string
  readonly finishTurn: (sessionId: string) => Promise<void>
  readonly beginTurn: (
    sessionId: string,
    options?: {
      readonly clientId?: string | undefined
      readonly clientPlatform?: BrowserClientPlatform | undefined
    }
  ) => Promise<void>
  readonly invokeRemoteGatewayCall: (
    origin: GatewayOrigin,
    path: string,
    args: unknown,
    options?: RemoteGatewayCallOptions
  ) => Promise<unknown>
  readonly closeSession: (sessionId: string) => Promise<void>
  readonly jobs: ExecutionJobs
  readonly handleGatewayRequest: (
    request: IncomingMessage,
    response: ServerResponse
  ) => Promise<void>
  readonly pluginConnection: (id: string) => Promise<PluginConnection>
  readonly subscribeConnections: (
    listener: (id: string, state: "connected" | "closed") => void
  ) => () => void
  readonly readResource: (
    id: string,
    uri: string,
    accountId?: string
  ) => Promise<ReadResourceResult>
  readonly appView: (viewId: string) => Promise<PluginAppView | undefined>
  readonly callAppTool: (
    serverId: string,
    toolName: string,
    args: Record<string, unknown>,
    accountId?: string
  ) => Promise<CallToolResult>
  readonly close: () => Promise<void>
}

export const CATALOG_STDIO_COMMAND = "codevisor-plugin"

export type CatalogLaunch =
  | { readonly transport: "stdio"; readonly command: string; readonly args: ReadonlyArray<string> }
  | { readonly transport: "http"; readonly url: string }

export interface McpCatalogResolver {
  readonly launch: (catalogId: string) => CatalogLaunch | undefined
  readonly oauthClient?: (catalogId: string) => string | undefined
}

export interface McpManagerConfig {
  readonly db: CodevisorDatabaseService
  readonly dataDir: string
  readonly baseUrl: string
  readonly serverId?: string
  readonly machine?: { readonly id: string; readonly name: string }
  readonly remoteInvoker?: GatewayRemoteInvoker
  readonly serverKind?: "local" | "remote"
  readonly skillSource?: SkillSource
  readonly packagedSkills?: ReadonlyArray<PackagedSkill>
  readonly catalog?: McpCatalogResolver
  readonly managedOAuth?: ManagedOAuthClients
  readonly accounts?: PluginAccountSource
  readonly executionTimers?: ExecutionTimers
  readonly oauthClock?: McpOAuthClock
  readonly oauthVault?: McpOAuthVault
  readonly makeBrowserProvider?: (() => BrowserUseProvider) | undefined
  readonly makeComputerProvider?:
    | (() => AutomationToolProvider & {
        readonly ensureSetup: () => Promise<void>
        readonly status: () => Readonly<Record<string, unknown>>
      })
    | undefined
}
