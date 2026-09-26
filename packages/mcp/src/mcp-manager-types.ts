import type { IncomingMessage, ServerResponse } from "node:http"

import type { QuestionAnswer, RuntimeEventSink } from "@codevisor/agent-runtime"
import type {
  BrowserPreference,
  BrowserUseConfiguration,
  CreateMcpServerRequest,
  McpAuthDetection,
  McpServer,
  McpTool,
  UpdateMcpServerRequest
} from "@codevisor/api"
import type { AutomationToolProvider, BrowserUseProvider } from "@codevisor/automation"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { ManagedSkillSpec } from "@codevisor/skills"
import type { WebSocket } from "ws"

import type { ToolGatewayConfig } from "./mcp-gateway.js"
import type { PluginToolSource } from "./mcp-plugin-tools.js"

/// Who a gateway call is made for. Local executions carry this machine's
/// identity; calls forwarded from another machine carry the caller's.
export interface GatewayOrigin {
  readonly machineId: string
  readonly machineName: string
  readonly sessionId?: string
  readonly sessionTitle?: string
  /// The client window that sent the originating turn's prompt.
  readonly clientId?: string
}

export interface GatewayCallContext {
  readonly sessionId?: string
  readonly projectId?: string
  readonly origin?: GatewayOrigin
}

/// Forwards one sandbox tool call to another machine's gateway. Reject with
/// a CodeExecutionToolError coded `machine_unavailable` (details: machineId,
/// name, lastSeen, phase) when the machine cannot be reached.
export type GatewayRemoteInvoker = (
  machine: string,
  path: string,
  args: unknown,
  origin: GatewayOrigin,
  signal?: AbortSignal
) => Promise<unknown>

export interface McpManager {
  readonly setBaseUrl: (url: string) => void
  readonly list: () => Promise<ReadonlyArray<McpServer>>
  readonly create: (request: CreateMcpServerRequest) => Promise<McpServer>
  readonly detectAuth: (url: string) => Promise<McpAuthDetection>
  readonly update: (id: string, request: UpdateMcpServerRequest) => Promise<McpServer>
  /// The decrypted STATIC secret material (bearer token, headers, env)
  /// for config-plane replication; OAuth material travels separately via
  /// oauthSyncState under refresh ownership. Empty bearer tokens
  /// normalize to absent.
  readonly staticSecrets: (id: string) => Promise<{
    readonly bearerToken?: string
    readonly headers?: Readonly<Record<string, string>>
    readonly env?: Readonly<Record<string, string>>
  }>
  /// The replication envelope for a server's OAuth material, present
  /// whenever tokens exist. `owner` names the machine that owns the
  /// refresh cycle — callers must only PUBLISH material they own; mirrors
  /// read it for observability ("credentials from <machine>").
  readonly oauthSyncState: (id: string) => Promise<
    | {
        readonly owner: string
        readonly rotatedAtMs: number
        readonly material: string
      }
    | undefined
  >
  /// Adopts another machine's OAuth material verbatim: replaces the stored
  /// OAuth state, records that machine as the refresh owner, cancels any
  /// local refresh timer, and drops the live connection so the next use
  /// picks up the new tokens. Identical re-imports are no-ops; malformed
  /// material is ignored.
  readonly importOAuthMaterial: (
    id: string,
    incoming: { readonly owner: string; readonly material: string }
  ) => Promise<void>
  /// Fires after this machine rotates (or first saves) a server's OAuth
  /// tokens, so the config plane can republish immediately.
  readonly subscribeCredentialsRotated: (listener: (id: string) => void) => () => void
  /// Takes over the refresh cycle of every server whose tokens name
  /// `legacyOwner` as their rotator — the identity this machine used to
  /// boot under. Without this, a renamed machine would treat its own
  /// tokens as a mirror's and never refresh them. Returns the adopted ids.
  readonly adoptOAuthOwnership: (legacyOwner: string) => Promise<ReadonlyArray<string>>
  /// Fires whenever a server record's visible state changes (definition,
  /// enabled flag, connection state, tool count, detail) or it is removed.
  /// The server publishes these as `mcp.updated` events.
  readonly subscribeServersChanged: (listener: (id: string) => void) => () => void
  readonly remove: (id: string) => Promise<void>
  readonly tools: (id?: string) => Promise<ReadonlyArray<McpTool>>
  readonly connect: (id: string) => Promise<McpServer>
  /// Machine-local suppression (Phase 18): names disabled ON THIS MACHINE
  /// by the config plane's mcp-overlays. Suppressed servers are dropped
  /// from session resolution, refused connection, and any live connection
  /// is closed — while the definition (and its fleet-wide enabled flag)
  /// stays untouched. Idempotent; pass the full current set each time.
  readonly setLocalSuppression: (names: ReadonlySet<string>) => Promise<void>
  readonly beginOAuth: (id: string, redirectBaseUrl?: string) => Promise<string>
  readonly finishOAuth: (state: string, code: string) => Promise<McpServer>
  readonly disconnectOAuth: (id: string) => Promise<McpServer>
  readonly resolved: (projectId?: string, sessionId?: string) => Promise<ReadonlyArray<McpServer>>
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
  /// Starts a turn; `clientId` names the window that sent the prompt and is
  /// exposed to that turn's executions as their origin client.
  readonly beginTurn: (
    sessionId: string,
    options?: { readonly clientId?: string | undefined }
  ) => Promise<void>
  /// Runs one gateway call on behalf of another machine (the server's
  /// `POST /v1/gateway/invoke`). Browser tabs and recordings are scoped to
  /// `remote:<origin.machineId>:<origin.sessionId>`.
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
  /// This machine's stable server id — the identity used for OAuth refresh
  /// ownership (exactly one machine rotates a server's tokens; the rest
  /// mirror them through config sync). Defaults to "local".
  readonly serverId?: string
  /// This machine's identity as other machines and the sandbox see it
  /// (`machines.current`). Defaults to `serverId` and the host name.
  readonly machine?: { readonly id: string; readonly name: string }
  /// Routes sandbox calls targeted at another machine. Without it, those
  /// calls fail with `machine_unavailable`.
  readonly remoteInvoker?: GatewayRemoteInvoker
  /// The server's --kind. Remote-kind servers cannot launch the local Chrome
  /// installer from Settings; composer setup can still hand the user off to
  /// the app running on that machine. Defaults to "local".
  readonly serverKind?: "local" | "remote"
  readonly syncManagedSkills?: (skills: ReadonlyArray<ManagedSkillSpec>) => Promise<void>
  /// Installed plugins' declared agent tools, exposed through the gateway as
  /// server "plugin" (`plugin.<pluginId>.<toolName>` paths). The server wires
  /// the plugins manager in directly — the structural PluginToolSource seam
  /// keeps this package free of a @codevisor/plugins dependency.
  readonly pluginTools?: PluginToolSource
  readonly makeBrowserProvider?: (() => BrowserUseProvider) | undefined
  readonly makeComputerProvider?:
    | (() => AutomationToolProvider & {
        readonly ensureSetup: () => Promise<void>
        readonly status: () => Readonly<Record<string, unknown>>
      })
    | undefined
}
