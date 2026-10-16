import type { IncomingMessage, ServerResponse } from "node:http"

import type { QuestionAnswer, RuntimeEventSink } from "@codevisor/agent-runtime"
import type {
  BrowserPreference,
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
  BrowserPreviewSubscription,
  BrowserPreviewViewer,
  BrowserUseProvider
} from "@codevisor/automation"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { WebSocket } from "ws"

import type { AutomationTool } from "./mcp-automation-use.js"
import type { ExecutionTimers } from "./mcp-gateway-execution.js"
import type { PackagedSkill, SkillSource } from "./mcp-gateway-skills.js"
import type { ToolGatewayConfig } from "./mcp-gateway.js"
import type { PluginToolSource } from "./mcp-plugin-tools.js"

export type { AutomationTool } from "./mcp-automation-use.js"

export interface GatewayOrigin {
  readonly machineId: string
  readonly machineName: string
  readonly sessionId?: string
  readonly sessionTitle?: string
  readonly clientId?: string
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
  readonly oauthSyncState: (id: string) => Promise<
    | {
        readonly owner: string
        readonly rotatedAtMs: number
        readonly material: string
      }
    | undefined
  >
  readonly importOAuthMaterial: (
    id: string,
    incoming: { readonly owner: string; readonly material: string }
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
  readonly subscribeBrowserPreview: (
    sessionId: string,
    viewer: BrowserPreviewViewer
  ) => BrowserPreviewSubscription
  readonly subscribeAutomationUse: (
    sessionId: string,
    listener: (tool: AutomationTool) => void
  ) => () => void
  readonly browserConfiguration: () => Promise<BrowserUseConfiguration>
  readonly setBrowserPreference: (
    preference: BrowserPreference | undefined
  ) => Promise<BrowserUseConfiguration>
  readonly openBrowserExtensionInstaller: () => Promise<BrowserUseConfiguration>
  readonly openBrowserExtensionFolder: () => Promise<BrowserUseConfiguration>
  readonly openBrowserExtensionsPage: () => Promise<BrowserUseConfiguration>
  readonly openBrowserExtensionWebStore: () => Promise<BrowserUseConfiguration>
  readonly browserExtensionArchive: () => string
  readonly browserExtensionIcon: () => string
  readonly finishTurn: (sessionId: string) => Promise<void>
  readonly beginTurn: (
    sessionId: string,
    options?: { readonly clientId?: string | undefined }
  ) => Promise<void>
  readonly invokeRemoteGatewayCall: (
    origin: GatewayOrigin,
    path: string,
    args: unknown,
    signal?: AbortSignal
  ) => Promise<unknown>
  readonly closeSession: (sessionId: string) => Promise<void>
  readonly handleGatewayRequest: (
    request: IncomingMessage,
    response: ServerResponse
  ) => Promise<void>
  readonly close: () => Promise<void>
}

export interface McpManagerConfig {
  readonly db: CodevisorDatabaseService
  readonly dataDir: string
  readonly serverId?: string
  readonly machine?: { readonly id: string; readonly name: string }
  readonly remoteInvoker?: GatewayRemoteInvoker
  readonly serverKind?: "local" | "remote"
  readonly skillSource?: SkillSource
  readonly packagedSkills?: ReadonlyArray<PackagedSkill>
  readonly pluginTools?: PluginToolSource
  readonly executionTimers?: ExecutionTimers
  readonly makeBrowserProvider?: (() => BrowserUseProvider) | undefined
  readonly makeComputerProvider?:
    | (() => AutomationToolProvider & {
        readonly ensureSetup: () => Promise<void>
        readonly status: () => Readonly<Record<string, unknown>>
      })
    | undefined
}
