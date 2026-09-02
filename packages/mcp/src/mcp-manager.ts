import type {
  BrowserPreference,
  BrowserUseConfiguration,
  CreateMcpServerRequest,
  McpAuthDetection,
  McpConnectionState,
  McpServer,
  McpTool,
  UpdateMcpServerRequest
} from "@codevisor/api"
import type { CodevisorDatabaseService, McpServerRecord } from "@codevisor/db"
import type { QuestionAnswer, RuntimeEventSink } from "@codevisor/agent-runtime"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import {
  auth,
  discoverOAuthProtectedResourceMetadata
} from "@modelcontextprotocol/sdk/client/auth.js"
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js"
import { isInitializeRequest, type Tool } from "@modelcontextprotocol/sdk/types.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto"
import type { IncomingMessage, ServerResponse } from "node:http"
import type WebSocket from "ws"
import { type AutomationToolProvider } from "@codevisor/automation"
import { makeBrowserSetupBroker } from "@codevisor/automation"
import { makeBrowserUseProvider, type BrowserUseProvider } from "@codevisor/automation"
import { makeCodeExecutor } from "@codevisor/automation"
import { makeCodevisorProvider } from "@codevisor/automation"
import { makeComputerUseProvider } from "@codevisor/automation"
import type { ManagedSkillSpec } from "@codevisor/skills"
import {
  BUILTIN_MCP_SERVERS,
  initializeAutomationProvider,
  managedAutomationSkills,
  unavailableBrowserProvider,
  unavailableComputerProvider
} from "./mcp-automation-builtins.js"
import {
  makeMcpGateway,
  type CatalogServer,
  type GatewayRuntime,
  type ToolGatewayConfig
} from "./mcp-gateway.js"
import type { PluginToolSource } from "./mcp-plugin-tools.js"
import { NodeStreamableHttpTransport } from "./mcp-http-transport.js"
import { makeMcpOAuthRuntime } from "./mcp-oauth.js"
import {
  decryptSecrets,
  encryptSecrets,
  loadEncryptionKey,
  type StoredOAuth,
  type StoredSecrets
} from "./mcp-secret-store.js"
import {
  errorMessage,
  readJsonBody,
  reportBackgroundFailure,
  requireHttpUrl,
  run,
  suggestedMcpName,
  validateRequest,
  type UpstreamConnection
} from "./mcp-support.js"

export { automationSkillPath } from "./mcp-automation-builtins.js"
export type { ToolGatewayConfig } from "./mcp-gateway.js"
export type { PluginGatewayTool, PluginToolSource } from "./mcp-plugin-tools.js"
export { NodeStreamableHttpTransport } from "./mcp-http-transport.js"
export { boundedMcpTimerDelay } from "./mcp-oauth.js"

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

export const makeMcpManager = (config: McpManagerConfig): McpManager => {
  const key = loadEncryptionKey(config.dataDir)
  // This is a cryptographic compatibility label, not a user-facing brand.
  // Keep it stable so resumed sessions retain a valid gateway credential.
  const gatewayBearerToken = createHash("sha256")
    .update("herdman-mcp-gateway-v1")
    .update(key)
    .digest("base64url")
  const connections = new Map<string, UpstreamConnection>()
  const connectionLocks = new Map<string, Promise<UpstreamConnection>>()
  const refreshTimers = new Map<string, ReturnType<typeof setTimeout>>()
  const refreshLocks = new Map<string, Promise<void>>()
  const refreshRetryAttempts = new Map<string, number>()
  const selfServerId = config.serverId ?? "local"
  const rotationListeners = new Set<(id: string) => void>()
  /* v8 ignore next 3 -- rotation events fire from the live OAuth refresh timer. */
  const emitCredentialsRotated = (id: string): void => {
    for (const listener of [...rotationListeners]) listener(id)
  }
  const gateways = new Map<string, GatewayRuntime>()
  const sessionGatewayIds = new Map<string, string>()
  let gatewayBaseUrl = "http://127.0.0.1:49361"
  let oauthBaseUrl = gatewayBaseUrl
  const codeExecutor = makeCodeExecutor({
    activeTimeoutMs: 30_000,
    memoryLimitBytes: 64 * 1024 * 1024,
    maxStackSizeBytes: 1024 * 1024
  })
  const browserProvider = initializeAutomationProvider(
    "Browser Use",
    config.makeBrowserProvider ?? (() => makeBrowserUseProvider(config.dataDir)),
    unavailableBrowserProvider
  )
  const computerProvider = initializeAutomationProvider(
    "Computer Use",
    config.makeComputerProvider ?? (() => makeComputerUseProvider(config.dataDir)),
    unavailableComputerProvider
  )
  const codevisorProvider = makeCodevisorProvider(
    () => gatewayBaseUrl,
    () => run(config.db.getOrCreateConnectionToken)
  )
  const automationProviders = new Map<string, AutomationToolProvider>([
    [browserProvider.id, browserProvider],
    [computerProvider.id, computerProvider],
    [codevisorProvider.id, codevisorProvider]
  ])
  const extensionFlowSupported = config.serverKind !== "remote"
  const browserSetupBroker = makeBrowserSetupBroker(config.db, browserProvider)
  const builtinProviderState = (
    id: "browser" | "computer",
    enabled: boolean
  ): { readonly connectionState: McpConnectionState; readonly detail?: string } => {
    if (!enabled) return { connectionState: "disconnected" }
    if (id === "browser") {
      const status = browserProvider.status()
      if (status.backend !== "missing") return { connectionState: "connected" }
      return {
        connectionState: "needsSetup",
        ...(typeof status.error === "string" ? { detail: status.error } : {})
      }
    }
    const status = computerProvider.status()
    if (status.available === true) return { connectionState: "connected" }
    return {
      connectionState: "unavailable",
      ...(typeof status.detail === "string" ? { detail: status.detail } : {})
    }
  }
  const syncManagedAutomationSkills = async (
    records: ReadonlyArray<McpServerRecord>
  ): Promise<void> => {
    if (config.syncManagedSkills === undefined) return
    await config.syncManagedSkills(
      managedAutomationSkills(
        new Set(
          records
            .filter((record) => record.enabled && !locallySuppressed.has(record.name))
            .map((record) => record.id)
        )
      )
    )
  }

  const syncManagedAutomationSkillsFromDb = async (): Promise<void> => {
    try {
      const records = await Promise.all(
        BUILTIN_MCP_SERVERS.map((builtin) => run(config.db.getMcpServer(builtin.id)))
      )
      await syncManagedAutomationSkills(
        records.filter((record): record is McpServerRecord => record !== undefined)
      )
    } catch (cause) {
      // Managed automation skills are optional. A missing packaged resource
      // or unreadable user skill directory must not fail an otherwise valid
      // MCP settings mutation or escape as an unhandled background rejection.
      reportBackgroundFailure("Managed automation skill synchronization failed", cause)
    }
  }

  const builtinsReady = Promise.all(
    BUILTIN_MCP_SERVERS.map(async (builtin) => {
      const provider = automationProviders.get(builtin.id)!
      const existing = await run(config.db.getMcpServer(builtin.id))
      if (existing !== undefined) {
        if (existing.kind !== builtin.kind) {
          throw new Error(`Reserved built-in MCP id is already in use: ${builtin.id}`)
        }
        const state = builtinProviderState(builtin.id, existing.enabled)
        return run(
          config.db.saveMcpServer({
            id: existing.id,
            name: existing.name,
            kind: existing.kind,
            transport: existing.transport,
            ...(existing.url === undefined ? {} : { url: existing.url }),
            ...(existing.command === undefined ? {} : { command: existing.command }),
            args: existing.args,
            enabled: existing.enabled,
            authType: existing.authType,
            ...(existing.oauthScope === undefined ? {} : { oauthScope: existing.oauthScope }),
            connectionState: state.connectionState,
            toolCount: provider.tools.length,
            ...(state.detail === undefined ? {} : { detail: state.detail }),
            ...(existing.secretCipher === undefined ? {} : { secretCipher: existing.secretCipher })
          })
        )
      }
      const state = builtinProviderState(builtin.id, true)
      return run(
        config.db.saveMcpServer({
          ...builtin,
          // Internal providers never spawn this transport. Keeping a valid
          // transport value preserves the existing external MCP wire schema.
          transport: "stdio",
          args: [],
          enabled: true,
          authType: "none",
          connectionState: state.connectionState,
          toolCount: provider.tools.length,
          ...(state.detail === undefined ? {} : { detail: state.detail })
        })
      )
    })
  )
    .then(syncManagedAutomationSkills)
    .catch((cause: unknown) => {
      // Built-in MCP registration and managed-skill installation are optional
      // feature initialization. Preserve external MCPs and the rest of the
      // server when a packaged resource or user skill directory is unavailable.
      reportBackgroundFailure("Built-in MCP initialization failed", cause)
    })

  const detectAuth = async (value: string): Promise<McpAuthDetection> => {
    const url = requireHttpUrl(value)
    const parsedUrl = new URL(url)
    const fallbackName = suggestedMcpName(parsedUrl)
    const response = await fetch(url, {
      method: "POST",
      signal: AbortSignal.timeout(5_000),
      headers: {
        accept: "application/json, text/event-stream",
        "content-type": "application/json"
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: "codevisor-auth-detection",
        method: "initialize",
        params: {
          protocolVersion: "2025-11-25",
          capabilities: {},
          clientInfo: { name: "Codevisor", version: "0.1.0" }
        }
      })
    })
    const challenge = response.headers.get("www-authenticate")?.toLowerCase() ?? ""
    /* v8 ignore next -- best-effort cleanup after reading only the authorization challenge. */
    await response.body?.cancel().catch(() => undefined)
    if (response.status !== 401 && response.status !== 403) {
      return {
        authType: "none",
        detail: "No authorization challenge detected",
        suggestedName: fallbackName
      }
    }
    if (challenge.includes("resource_metadata=")) {
      return {
        authType: "oauth",
        detail: "OAuth protected resource detected",
        suggestedName: fallbackName
      }
    }
    try {
      await discoverOAuthProtectedResourceMetadata(new URL(url))
      return {
        authType: "oauth",
        detail: "OAuth protected resource detected",
        suggestedName: fallbackName
      }
    } catch {
      return {
        authType: "bearer",
        detail: challenge.includes("bearer")
          ? "Bearer token authorization detected"
          : "Authorization required; bearer token selected",
        suggestedName: fallbackName
      }
    }
  }

  const record = async (id: string): Promise<McpServerRecord> => {
    await builtinsReady
    const value = await run(config.db.getMcpServer(id))
    if (value === undefined) throw new Error(`MCP server not found: ${id}`)
    return value
  }

  const secrets = (server: McpServerRecord): StoredSecrets =>
    decryptSecrets(key, server.secretCipher)

  const publicServer = (server: McpServerRecord): McpServer => {
    const { secretCipher: _secretCipher, ...visible } = server
    const stored = secrets(server)
    return {
      ...visible,
      headerNames: Object.keys(stored.headers ?? {}).sort((left, right) =>
        left.localeCompare(right)
      ),
      environmentNames: Object.keys(stored.env ?? {}).sort((left, right) =>
        left.localeCompare(right)
      )
    }
  }

  const mergedSecretRecord = (
    current: Readonly<Record<string, string>> | undefined,
    updates: Readonly<Record<string, string>> | undefined,
    removals: ReadonlyArray<string> | undefined
  ): Record<string, string> | undefined => {
    const next = { ...current, ...updates }
    for (const name of removals ?? []) delete next[name]
    return Object.keys(next).length === 0 ? undefined : next
  }

  const saveRecord = (server: McpServerRecord, patch: Partial<McpServerRecord> = {}) => {
    const url = patch.url ?? server.url
    const command = patch.command ?? server.command
    const oauthScope = patch.oauthScope ?? server.oauthScope
    const detail = patch.detail
    const secretCipher = patch.secretCipher ?? server.secretCipher
    return run(
      config.db.saveMcpServer({
        id: server.id,
        name: patch.name ?? server.name,
        kind: patch.kind ?? server.kind,
        transport: patch.transport ?? server.transport,
        ...(url === undefined ? {} : { url }),
        ...(command === undefined ? {} : { command }),
        args: patch.args ?? server.args,
        enabled: patch.enabled ?? server.enabled,
        authType: patch.authType ?? server.authType,
        ...(oauthScope === undefined ? {} : { oauthScope }),
        /* v8 ignore next -- every internal save transition supplies its resulting connection state. */
        connectionState: patch.connectionState ?? server.connectionState,
        toolCount: patch.toolCount ?? server.toolCount,
        ...(detail === undefined ? {} : { detail }),
        /* v8 ignore next -- manager-owned records always have an encrypted secret payload. */
        ...(secretCipher === undefined ? {} : { secretCipher })
      })
    )
  }

  const refreshBuiltinProviderStates = async (): Promise<void> => {
    await builtinsReady
    for (const builtin of BUILTIN_MCP_SERVERS) {
      const current = await record(builtin.id)
      const state = builtinProviderState(builtin.id, current.enabled)
      // Preserve an actionable runtime failure (for example a missing desktop
      // D-Bus session) until an explicit reconnect. The ordinary macOS
      // "open the app" state remains dynamic as the app starts and stops.
      if (
        builtin.id === "computer" &&
        current.connectionState === "unavailable" &&
        state.connectionState === "connected" &&
        current.detail !== undefined &&
        current.detail !== "Open the native Codevisor app to use Computer Use"
      ) {
        continue
      }
      if (
        current.connectionState === state.connectionState &&
        current.detail === state.detail &&
        current.toolCount === automationProviders.get(builtin.id)!.tools.length
      ) {
        continue
      }
      await saveRecord(current, {
        connectionState: state.connectionState,
        toolCount: automationProviders.get(builtin.id)!.tools.length,
        ...(state.detail === undefined ? {} : { detail: state.detail })
      })
    }
  }

  /* v8 ignore start -- these helpers are used exclusively by the live OAuth adapter below. */
  const replaceSecrets = async (
    id: string,
    mutate: (current: StoredSecrets) => StoredSecrets
  ): Promise<McpServerRecord> => {
    const current = await record(id)
    return saveRecord(current, { secretCipher: encryptSecrets(key, mutate(secrets(current))) })
  }

  let locallySuppressed: ReadonlySet<string> = new Set()

  const closeConnection = async (id: string): Promise<void> => {
    const existing = connections.get(id)
    connections.delete(id)
    connectionLocks.delete(id)
    if (existing !== undefined) await existing.close().catch(() => undefined)
  }

  const callbackUrl = (): string => new URL("/v1/mcps/oauth/callback", oauthBaseUrl).toString()
  /* v8 ignore stop */

  const listAllUpstreamTools = async (client: Client): Promise<ReadonlyArray<Tool>> => {
    const tools: Tool[] = []
    let cursor: string | undefined
    do {
      const page = await client.listTools(cursor === undefined ? undefined : { cursor })
      tools.push(...page.tools)
      cursor = page.nextCursor
    } while (cursor !== undefined)
    return tools
  }

  const connectUpstream = async (
    id: string,
    options: { readonly allowDisabled?: boolean; readonly preserveState?: boolean } = {}
  ): Promise<UpstreamConnection> => {
    const cached = connections.get(id)
    if (cached !== undefined) return cached
    const pending = connectionLocks.get(id)
    /* v8 ignore next -- concurrent connection callers normally observe the completed cache above. */
    if (pending !== undefined) return pending

    const connecting = (async () => {
      const server = await record(id)
      if (server.kind !== "managed") throw new Error(`${server.name} is an internal provider`)
      if (!server.enabled && options.allowDisabled !== true) {
        throw new Error(`${server.name} is disabled`)
      }
      if (locallySuppressed.has(server.name)) {
        throw new Error(`${server.name} is disabled on this machine`)
      }
      /* v8 ignore next -- preserveState is reserved for the live OAuth validation path. */
      if (options.preserveState !== true) {
        await saveRecord(server, { connectionState: "connecting", detail: undefined })
      }
      const stored = secrets(server)
      const client = new Client({ name: "Codevisor", version: "0.1.0" }, { capabilities: {} })
      // An empty bearer token is NO token — `""` must never shadow the
      // OAuth access token a sync import delivered (PostHog answers an
      // empty Authorization header with "No token provided" forever).
      const bearer =
        stored.bearerToken === undefined || stored.bearerToken === ""
          ? undefined
          : stored.bearerToken
      const accessToken = bearer ?? stored.oauth?.tokens?.access_token
      const transport =
        server.transport === "stdio"
          ? new StdioClientTransport({
              /* v8 ignore next -- stdio records are validated to require a command before saving. */
              command: server.command ?? "",
              args: [...server.args],
              env: { ...process.env, ...stored.env } as Record<string, string>,
              stderr: "pipe"
            })
          : new NodeStreamableHttpTransport(
              new URL(requireHttpUrl(server.url)),
              accessToken,
              stored.headers
            )
      let phase = "initialize"
      try {
        await client.connect(transport as unknown as Transport)
        phase = "tools/list"
        const tools = await listAllUpstreamTools(client)
        const connection: UpstreamConnection = {
          client,
          close: () => client.close(),
          tools
        }
        connections.set(id, connection)
        const updated = await record(id)
        await saveRecord(updated, {
          connectionState: "connected",
          toolCount: tools.length,
          detail: undefined
        })
        return connection
      } catch (cause) {
        /* v8 ignore next -- best-effort cleanup after the original connection failure. */
        await client.close().catch(() => undefined)
        console.error(
          `MCP connection failed for ${server.name} during ${phase}: ${errorMessage(cause)}`
        )
        const updated = await record(id)
        /* v8 ignore next -- OAuth connection failures are handled by live completion validation. */
        const needsAuthorization = server.authType === "oauth" && accessToken === undefined
        await saveRecord(updated, {
          /* v8 ignore next -- OAuth failures are classified by the live validation path. */
          connectionState: needsAuthorization ? "needsAuthorization" : "error",
          detail: errorMessage(cause)
        })
        throw cause
      } finally {
        connectionLocks.delete(id)
      }
    })()
    connectionLocks.set(id, connecting)
    return connecting
  }

  const { allTools, createGatewayConnection, gatewayRuntime, refreshGatewayInventories } =
    makeMcpGateway({
      automationProviders,
      browserSetupBroker,
      codeExecutor,
      codevisorProvider,
      config,
      connectUpstream,
      gateways,
      isSuppressed: (name) => locallySuppressed.has(name),
      record
    })

  // Plugin installs/uninstalls change the plugin-tool inventory the gateway
  // advertises; refresh every live gateway's tool descriptions on change.
  const unsubscribePluginTools = config.pluginTools?.subscribeInstalled(() => {
    void refreshGatewayInventories().catch((cause: unknown) =>
      reportBackgroundFailure("Plugin tool inventory refresh failed", cause)
    )
  })

  const { oauthProvider, scheduleRefresh, validateOAuthConnection } = makeMcpOAuthRuntime({
    callbackUrl,
    closeConnection,
    connectUpstream,
    onRotated: emitCredentialsRotated,
    record,
    refreshGatewayInventories,
    refreshLocks,
    refreshRetryAttempts,
    refreshTimers,
    replaceSecrets,
    saveRecord,
    secrets,
    selfServerId
  })

  const manager: McpManager = {
    setBaseUrl: (url) => {
      const parsed = new URL(url)
      gatewayBaseUrl = `${parsed.protocol}//127.0.0.1:${parsed.port}`
      oauthBaseUrl = gatewayBaseUrl
      browserProvider.configureExtensionRelay(gatewayBaseUrl)
    },
    list: async () => {
      await refreshBuiltinProviderStates()
      return (await run(config.db.listMcpServers)).map(publicServer)
    },
    detectAuth,
    create: async (request) => {
      await builtinsReady
      validateRequest(request)
      const authType =
        request.transport === "stdio"
          ? "none"
          : (request.authType ?? (await detectAuth(requireHttpUrl(request.url))).authType)
      const id = randomUUID()
      const oauthState = `${id}.${randomUUID()}`
      const oauth: StoredOAuth = {
        state: oauthState,
        ...(request.oauthClientId === undefined
          ? {}
          : { configuredClientId: request.oauthClientId }),
        ...(request.oauthClientSecret === undefined
          ? {}
          : { configuredClientSecret: request.oauthClientSecret })
      }
      const stored: StoredSecrets = {
        ...(request.env === undefined ? {} : { env: request.env }),
        ...(request.headers === undefined ? {} : { headers: request.headers }),
        // "" is the editor's untouched field, not a credential.
        ...(request.bearerToken === undefined || request.bearerToken === ""
          ? {}
          : { bearerToken: request.bearerToken }),
        ...(authType !== "oauth"
          ? {}
          : {
              oauth
            })
      }
      const url = request.transport === "http" ? requireHttpUrl(request.url) : undefined
      const command = request.transport === "stdio" ? request.command : undefined
      const saved = await run(
        config.db.saveMcpServer({
          id,
          name: request.name.trim(),
          kind: "managed",
          transport: request.transport,
          ...(url === undefined ? {} : { url }),
          ...(command === undefined ? {} : { command }),
          args: request.args ?? [],
          enabled: authType === "oauth" ? false : (request.enabled ?? true),
          authType,
          ...(request.oauthScope === undefined ? {} : { oauthScope: request.oauthScope }),
          connectionState: authType === "oauth" ? "needsAuthorization" : "disconnected",
          toolCount: 0,
          secretCipher: encryptSecrets(key, stored)
        })
      )
      if (saved.enabled && authType !== "oauth") {
        await manager.connect(saved.id).catch(() => undefined)
      }
      await refreshGatewayInventories()
      return publicServer(await record(saved.id))
    },
    update: async (id, request) => {
      await builtinsReady
      const current = await record(id)
      if (!current.canEdit) {
        const unsupported = Object.keys(request).filter((key) => key !== "enabled")
        if (unsupported.length > 0) throw new Error(`${current.name} is managed by Codevisor`)
        const enabled = request.enabled ?? current.enabled
        const state = builtinProviderState(current.id as "browser" | "computer", enabled)
        const saved = await saveRecord(current, {
          enabled,
          connectionState: state.connectionState,
          ...(state.detail === undefined ? {} : { detail: state.detail })
        })
        const provider = automationProviders.get(saved.id)!
        if (!saved.enabled) {
          await provider.close()
        } else if (saved.id === "browser" && state.connectionState === "needsSetup") {
          // Browser downloads can take several minutes. Keep the toggle
          // responsive and let the settings view observe setup progress.
          void manager.connect(saved.id).catch(() => undefined)
        } else if (state.connectionState !== "unavailable") {
          await manager.connect(saved.id).catch(() => undefined)
        }
        await syncManagedAutomationSkillsFromDb()
        await refreshGatewayInventories()
        return publicServer(await record(saved.id))
      }
      const currentSecrets = secrets(current)
      const transport = current.transport
      const url = request.url ?? current.url
      const command = request.command ?? current.command
      validateRequest({
        transport,
        url,
        command,
        env: request.env,
        headers: request.headers,
        authType: request.authType,
        bearerToken: request.bearerToken,
        oauthScope: request.oauthScope,
        oauthClientId: request.oauthClientId,
        oauthClientSecret: request.oauthClientSecret
      })
      await closeConnection(id)
      const updatedOauth: StoredOAuth | undefined =
        request.oauthClientId === undefined && request.oauthClientSecret === undefined
          ? currentSecrets.oauth
          : {
              ...currentSecrets.oauth,
              ...(request.oauthClientId === undefined
                ? {}
                : { configuredClientId: request.oauthClientId }),
              ...(request.oauthClientSecret === undefined
                ? {}
                : { configuredClientSecret: request.oauthClientSecret })
            }
      const nextSecrets: StoredSecrets = {
        ...currentSecrets,
        ...(request.env === undefined && request.removeEnv === undefined
          ? {}
          : { env: mergedSecretRecord(currentSecrets.env, request.env, request.removeEnv) }),
        ...(request.headers === undefined && request.removeHeaders === undefined
          ? {}
          : {
              headers: mergedSecretRecord(
                currentSecrets.headers,
                request.headers,
                request.removeHeaders
              )
            }),
        ...(request.bearerToken === undefined ? {} : { bearerToken: request.bearerToken }),
        ...(updatedOauth === undefined ? {} : { oauth: updatedOauth })
      }
      const nextAuthType = request.authType ?? current.authType
      const oauthIsAuthorized = nextSecrets.oauth?.tokens !== undefined
      const enabled =
        nextAuthType === "oauth" && !oauthIsAuthorized
          ? false
          : (request.enabled ?? current.enabled)
      const saved = await saveRecord(current, {
        name: request.name ?? current.name,
        url,
        command,
        args: request.args ?? current.args,
        enabled,
        authType: nextAuthType,
        oauthScope: request.oauthScope ?? current.oauthScope,
        connectionState:
          nextAuthType === "oauth" && !oauthIsAuthorized ? "needsAuthorization" : "disconnected",
        toolCount: 0,
        detail: undefined,
        secretCipher: encryptSecrets(key, nextSecrets)
      })
      /* v8 ignore next -- authorized OAuth reconnects are handled by live completion validation. */
      if (saved.enabled && (saved.authType !== "oauth" || oauthIsAuthorized)) {
        await manager.connect(id).catch(() => undefined)
      }
      await refreshGatewayInventories()
      return publicServer(await record(id))
    },
    setLocalSuppression: async (names) => {
      await builtinsReady
      locallySuppressed = new Set(names)
      if (names.size > 0) {
        for (const server of await run(config.db.listMcpServers)) {
          if (!names.has(server.name)) continue
          if (connections.has(server.id)) {
            await closeConnection(server.id)
            await saveRecord(server, { connectionState: "disconnected", detail: undefined })
          }
        }
      }
      await refreshGatewayInventories()
      // Machine-disabling a built-in (Computer Use) must also retract its
      // managed skill; re-derive from the store now that suppression changed.
      await syncManagedAutomationSkillsFromDb()
    },
    staticSecrets: async (id) => {
      const stored = secrets(await record(id))
      return {
        ...(stored.bearerToken === undefined || stored.bearerToken === ""
          ? {}
          : { bearerToken: stored.bearerToken }),
        ...(stored.headers === undefined ? {} : { headers: stored.headers }),
        ...(stored.env === undefined ? {} : { env: stored.env })
      }
    },
    oauthSyncState: async (id) => {
      const server = await record(id)
      if (server.authType !== "oauth") return undefined
      const oauth = secrets(server).oauth
      if (oauth?.tokens === undefined) return undefined
      const material: StoredOAuth = {
        ...(oauth.clientInformation === undefined
          ? {}
          : { clientInformation: oauth.clientInformation }),
        tokens: oauth.tokens,
        ...(oauth.tokensSavedAt === undefined ? {} : { tokensSavedAt: oauth.tokensSavedAt }),
        ...(oauth.discoveryState === undefined ? {} : { discoveryState: oauth.discoveryState }),
        ...(oauth.configuredClientId === undefined
          ? {}
          : { configuredClientId: oauth.configuredClientId }),
        ...(oauth.configuredClientSecret === undefined
          ? {}
          : { configuredClientSecret: oauth.configuredClientSecret })
      }
      return {
        owner: oauth.refreshOwner ?? selfServerId,
        rotatedAtMs: oauth.tokensSavedAt ?? 0,
        material: JSON.stringify(material)
      }
    },
    importOAuthMaterial: async (id, incoming) => {
      const current = secrets(await record(id)).oauth
      let parsed: StoredOAuth
      try {
        parsed = JSON.parse(incoming.material) as StoredOAuth
      } catch {
        return
      }
      if (typeof parsed !== "object" || parsed === null) return
      // Identical re-imports must not thrash the live connection.
      if (
        current?.refreshOwner === incoming.owner &&
        (current?.tokensSavedAt ?? 0) === (parsed.tokensSavedAt ?? 0)
      ) {
        return
      }
      const timer = refreshTimers.get(id)
      if (timer !== undefined) clearTimeout(timer)
      refreshTimers.delete(id)
      await replaceSecrets(id, (value) => ({
        ...value,
        oauth: { ...parsed, refreshOwner: incoming.owner }
      }))
      await closeConnection(id)
    },
    subscribeCredentialsRotated: (listener) => {
      rotationListeners.add(listener)
      return () => {
        rotationListeners.delete(listener)
      }
    },
    remove: async (id) => {
      await builtinsReady
      const current = await record(id)
      if (!current.canRemove) throw new Error(`${current.name} cannot be removed`)
      await closeConnection(id)
      const timer = refreshTimers.get(id)
      /* v8 ignore next -- timers only exist for the live OAuth refresh adapter. */
      if (timer !== undefined) clearTimeout(timer)
      refreshTimers.delete(id)
      await run(config.db.deleteMcpServer(id))
      await refreshGatewayInventories()
    },
    tools: async (id) => {
      const selected: CatalogServer | undefined =
        id === undefined
          ? undefined
          : id === "codevisor"
            ? { id: "codevisor", name: "Codevisor" }
            : await record(id)
      const pairs =
        id === undefined
          ? await allTools()
          : (automationProviders.get(id)?.tools ?? (await connectUpstream(id)).tools).map(
              (tool) => ({ server: selected!, tool })
            )
      return pairs.map(({ server, tool }) => ({
        serverId: server.id,
        serverName: server.name,
        name: tool.name,
        ...(tool.title === undefined ? {} : { title: tool.title }),
        ...(tool.description === undefined ? {} : { description: tool.description }),
        inputSchema: tool.inputSchema
      }))
    },
    connect: async (id) => {
      await closeConnection(id)
      const provider = automationProviders.get(id)
      if (provider !== undefined) {
        try {
          if (id === "browser") await browserProvider.ensureSetup()
          if (id === "computer") await computerProvider.ensureSetup()
          const current = await record(id)
          return publicServer(
            await saveRecord(current, {
              connectionState: "connected",
              toolCount: provider.tools.length,
              detail: undefined
            })
          )
        } catch (cause) {
          await saveRecord(await record(id), {
            connectionState: id === "browser" ? "needsSetup" : "unavailable",
            toolCount: provider.tools.length,
            detail: errorMessage(cause)
          })
          throw cause
        }
      }
      await connectUpstream(id)
      return publicServer(await record(id))
    },
    /* v8 ignore start -- browser OAuth lifecycle is covered by the live provider integration flow. */
    beginOAuth: async (id, redirectBaseUrl) => {
      if (redirectBaseUrl !== undefined) oauthBaseUrl = redirectBaseUrl
      const server = await record(id)
      if (server.transport !== "http" || server.authType !== "oauth") {
        throw new Error("This MCP server is not configured for OAuth")
      }
      await closeConnection(id)
      const redirectUrl = callbackUrl()
      const state = `${id}.${randomUUID()}`
      await replaceSecrets(id, (value) => ({
        ...value,
        oauth: { ...value.oauth, redirectUrl, state }
      }))
      const provider = oauthProvider(id, redirectUrl)
      const result = await auth(provider, {
        serverUrl: requireHttpUrl(server.url),
        ...(server.oauthScope === undefined ? {} : { scope: server.oauthScope })
      })
      if (result === "AUTHORIZED") {
        await saveRecord(await record(id), {
          enabled: false,
          connectionState: "needsAuthorization",
          detail: undefined
        })
        void validateOAuthConnection(id).catch((cause: unknown) =>
          reportBackgroundFailure(`OAuth validation failed for MCP ${id}`, cause)
        )
        return new URL("/v1/mcps/oauth/complete", oauthBaseUrl).toString()
      }
      if (provider.authorizationUrl === undefined) throw new Error("OAuth did not return a URL")
      await saveRecord(await record(id), {
        connectionState: "needsAuthorization",
        detail: undefined
      })
      return provider.authorizationUrl.toString()
    },
    finishOAuth: async (state, code) => {
      const id = state.split(".", 1)[0]
      if (id === undefined || id.length === 0) throw new Error("Invalid OAuth state")
      const server = await record(id)
      const expected = secrets(server).oauth?.state
      if (expected === undefined || expected !== state) throw new Error("Invalid OAuth state")
      const result = await auth(oauthProvider(id, secrets(server).oauth?.redirectUrl), {
        serverUrl: requireHttpUrl(server.url),
        authorizationCode: code,
        ...(server.oauthScope === undefined ? {} : { scope: server.oauthScope })
      })
      if (result !== "AUTHORIZED") throw new Error("OAuth authorization did not complete")
      await replaceSecrets(id, (value) => ({
        ...value,
        oauth: { ...value.oauth, codeVerifier: undefined, state: undefined }
      }))
      await saveRecord(await record(id), {
        enabled: false,
        connectionState: "needsAuthorization",
        detail: undefined
      })
      void validateOAuthConnection(id).catch((cause: unknown) =>
        reportBackgroundFailure(`OAuth validation failed for MCP ${id}`, cause)
      )
      return publicServer(await record(id))
    },
    disconnectOAuth: async (id) => {
      await closeConnection(id)
      const current = await replaceSecrets(id, (value) => ({
        ...value,
        oauth: {
          state: `${id}.${randomUUID()}`,
          configuredClientId: value.oauth?.configuredClientId,
          configuredClientSecret: value.oauth?.configuredClientSecret
        }
      }))
      return publicServer(
        await saveRecord(current, {
          enabled: false,
          connectionState: "needsAuthorization",
          toolCount: 0,
          detail: undefined
        })
      )
    },
    /* v8 ignore stop */
    resolved: async (projectId, sessionId) => {
      await builtinsReady
      return (await run(config.db.resolveMcpServers(projectId, sessionId)))
        .filter((server) => !locallySuppressed.has(server.name))
        .map(publicServer)
    },
    setProjectEnabled: async (projectId, serverId, enabled) => {
      await run(config.db.setProjectMcpEnabled(projectId, serverId, enabled))
      await refreshGatewayInventories()
      return manager.resolved(projectId)
    },
    setSessionEnabled: async (sessionId, serverId, enabled, projectId) => {
      await run(config.db.setSessionMcpEnabled(sessionId, serverId, enabled))
      await refreshGatewayInventories()
      return manager.resolved(projectId, sessionId)
    },
    issueGateway: async (sessionId, projectId, sink) => {
      await builtinsReady
      if (sink !== undefined) {
        browserSetupBroker.setSink(sessionId, sink)
      }
      const existingId = sessionGatewayIds.get(sessionId)
      if (existingId !== undefined && gateways.has(existingId)) {
        const existingUrl = new URL("/mcp/gateway", gatewayBaseUrl)
        existingUrl.searchParams.set("gateway", existingId)
        return { name: "codevisor", url: existingUrl.toString(), bearerToken: gatewayBearerToken }
      }
      const gatewayId = randomBytes(24).toString("base64url")
      const runtime = await gatewayRuntime(sessionId, projectId)
      gateways.set(gatewayId, runtime)
      sessionGatewayIds.set(sessionId, gatewayId)
      const url = new URL("/mcp/gateway", gatewayBaseUrl)
      url.searchParams.set("gateway", gatewayId)
      return {
        name: "codevisor",
        url: url.toString(),
        bearerToken: gatewayBearerToken
      }
    },
    answerQuestion: (sessionId, questionId, answer) =>
      browserSetupBroker.answerQuestion(sessionId, questionId, answer),
    acceptBrowserExtension: (socket) => browserProvider.acceptExtensionConnection(socket),
    browserConfiguration: async () => {
      const status = browserProvider.status()
      return {
        ...(await run(config.db.getBrowserPreference).then((preferredBrowser) =>
          preferredBrowser === undefined ? {} : { preferredBrowser }
        )),
        chromeAvailable: status.chromeAvailable,
        chromeConnected: status.extensionConnected,
        managedAvailable: status.backend !== "missing",
        extensionFlowSupported,
        ...(status.developmentExtensionPath === undefined
          ? {}
          : { developmentExtensionPath: status.developmentExtensionPath })
      }
    },
    setBrowserPreference: async (preference) => {
      await run(config.db.setBrowserPreference(preference))
      return manager.browserConfiguration()
    },
    openBrowserExtensionInstaller: async () => {
      browserProvider.openDevelopmentExtensionInstaller()
      return manager.browserConfiguration()
    },
    openBrowserExtensionFolder: async () => {
      browserProvider.openDevelopmentExtensionFolder()
      return manager.browserConfiguration()
    },
    openBrowserExtensionsPage: async () => {
      browserProvider.openDevelopmentExtensionPage()
      return manager.browserConfiguration()
    },
    openBrowserExtensionWebStore: async () => {
      browserProvider.openExtensionWebStore()
      return manager.browserConfiguration()
    },
    browserExtensionArchive: () => browserProvider.extensionArchivePath(),
    browserExtensionIcon: () => browserProvider.extensionIconPath(),
    closeSession: async (sessionId) => {
      const gatewayId = sessionGatewayIds.get(sessionId)
      sessionGatewayIds.delete(sessionId)
      if (gatewayId !== undefined) {
        const gateway = gateways.get(gatewayId)
        gateways.delete(gatewayId)
        await Promise.all(
          [...(gateway?.connections.values() ?? [])].map((connection) =>
            connection.server.close().catch(() => undefined)
          )
        )
      }
      await Promise.all(
        [...automationProviders.values()].map((provider) => provider.closeSession(sessionId))
      )
      await browserSetupBroker.closeSession(sessionId)
    },
    handleGatewayRequest: async (request, response) => {
      const authorization = request.headers.authorization
      const token = authorization?.startsWith("Bearer ") ? authorization.slice(7) : undefined
      const authorized =
        token !== undefined &&
        token.length === gatewayBearerToken.length &&
        timingSafeEqual(Buffer.from(token), Buffer.from(gatewayBearerToken))
      if (!authorized) {
        response.writeHead(401, { "content-type": "application/json" })
        response.end(JSON.stringify({ error: "Invalid Codevisor tool gateway token" }))
        return
      }
      /* v8 ignore next -- Node HTTP requests always carry a URL. */
      const gatewayId = new URL(request.url ?? "/", gatewayBaseUrl).searchParams.get("gateway")
      /* v8 ignore next -- missing and unknown gateway capabilities share the tested 404 response. */
      const runtime = gatewayId === null ? undefined : gateways.get(gatewayId)
      if (runtime === undefined) {
        response.writeHead(404, { "content-type": "application/json" })
        response.end(JSON.stringify({ error: "Codevisor tool gateway session not found" }))
        return
      }

      // Route follow-up requests to their existing MCP connection. (Node
      // folds duplicate non-set-cookie headers into one string, so the
      // header is a string or absent — never an array.)
      const sessionHeader = request.headers["mcp-session-id"]
      const mcpSessionId = typeof sessionHeader === "string" ? sessionHeader : undefined
      const existing =
        mcpSessionId === undefined ? undefined : runtime.connections.get(mcpSessionId)
      if (existing !== undefined) {
        await existing.transport.handleRequest(request, response)
        return
      }
      if (mcpSessionId !== undefined) {
        // A session id we no longer know (e.g. a connection from before a
        // server restart). 404 tells spec-following clients to re-initialize.
        response.writeHead(404, { "content-type": "application/json" })
        response.end(JSON.stringify({ error: "Unknown MCP session — re-initialize" }))
        return
      }

      // No session id: only a fresh `initialize` may open a new connection.
      // Harnesses re-initialize mid-session (codex 0.145+ rebuilds its MCP
      // connections on account/plugin changes), so every handshake gets its
      // own server + transport pair for the lifetime of that MCP session.
      if (request.method !== "POST") {
        response.writeHead(405, { "content-type": "application/json" })
        response.end(JSON.stringify({ error: "Method not allowed without an MCP session" }))
        return
      }
      let body: unknown
      try {
        body = await readJsonBody(request)
      } catch {
        response.writeHead(400, { "content-type": "application/json" })
        response.end(JSON.stringify({ error: "Invalid JSON body" }))
        return
      }
      const isInitialize = Array.isArray(body)
        ? body.some((entry) => isInitializeRequest(entry))
        : isInitializeRequest(body)
      if (!isInitialize) {
        response.writeHead(400, { "content-type": "application/json" })
        response.end(JSON.stringify({ error: "Send an initialize request to open an MCP session" }))
        return
      }
      const connection = await createGatewayConnection(runtime)
      await connection.transport.handleRequest(request, response, body)
    },
    close: async () => {
      unsubscribePluginTools?.()
      /* v8 ignore next -- timers only exist for the live OAuth refresh adapter. */
      for (const timer of refreshTimers.values()) clearTimeout(timer)
      await Promise.all([...connections.keys()].map(closeConnection))
      await browserSetupBroker.close()
      await Promise.all([...automationProviders.values()].map((provider) => provider.close()))
      await Promise.all(
        [...gateways.values()].flatMap((gateway) =>
          [...gateway.connections.values()].map(async (connection) => {
            /* v8 ignore next -- best-effort cleanup; normal gateway shutdown resolves cleanly. */
            await connection.server.close().catch(() => undefined)
          })
        )
      )
      gateways.clear()
      sessionGatewayIds.clear()
    }
  }

  /* v8 ignore start -- startup token restoration feeds the live OAuth refresh scheduler above. */
  void run(config.db.listMcpServers)
    .then((servers) => {
      for (const server of servers) {
        const oauth = secrets(server).oauth
        if (oauth?.tokens !== undefined) scheduleRefresh(server, oauth.tokens)
      }
    })
    .catch((cause: unknown) => reportBackgroundFailure("MCP OAuth restoration failed", cause))
  /* v8 ignore stop */

  return manager
}
