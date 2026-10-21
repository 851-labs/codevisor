import { createHash } from "node:crypto"
import { hostname } from "node:os"

import type { McpConnectionState, McpServer } from "@codevisor/api"
import {
  makeBrowserSetupBroker,
  makeBrowserUseProvider,
  makeCodeExecutor,
  makeCodevisorProvider,
  makeComputerUseProvider,
  type AutomationToolProvider
} from "@codevisor/automation"
import type { McpServerRecord } from "@codevisor/db"

import {
  BUILTIN_MCP_SERVERS,
  type BuiltinMcpId,
  initializeAutomationProvider,
  unavailableBrowserProvider,
  unavailableComputerProvider
} from "./mcp-automation-builtins.js"
import { makeAutomationUse } from "./mcp-automation-use.js"
import type { GatewayRuntime } from "./mcp-gateway.js"
import type { McpManagerConfig } from "./mcp-manager-types.js"
import {
  decryptSecrets,
  encryptSecrets,
  loadEncryptionKey,
  type StoredSecrets
} from "./mcp-secret-store.js"
import { reportBackgroundFailure, run, type UpstreamConnection } from "./mcp-support.js"

export interface McpManagerState {
  gatewayBaseUrl: string
  oauthBaseUrl: string
  locallySuppressed: ReadonlySet<string>
}

const DEFAULT_GATEWAY_BASE_URL = "http://127.0.0.1:49361"

const visibleSignature = (server: McpServerRecord): string =>
  JSON.stringify([
    server.name,
    server.kind,
    server.transport,
    server.url,
    server.command,
    server.args,
    server.enabled,
    server.authType,
    server.oauthScope,
    server.connectionState,
    server.toolCount,
    server.detail
  ])

export const makeMcpManagerCore = (config: McpManagerConfig) => {
  const key = loadEncryptionKey(config.dataDir)
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
  /* v8 ignore next 3 */
  const emitCredentialsRotated = (id: string): void => {
    for (const listener of Array.from(rotationListeners)) listener(id)
  }
  const changeListeners = new Set<(id: string) => void>()
  const emitServerChanged = (id: string): void => {
    for (const listener of Array.from(changeListeners)) listener(id)
  }
  const gateways = new Map<string, GatewayRuntime>()
  const sessionGatewayIds = new Map<string, string>()
  const state: McpManagerState = {
    gatewayBaseUrl: DEFAULT_GATEWAY_BASE_URL,
    oauthBaseUrl: DEFAULT_GATEWAY_BASE_URL,
    locallySuppressed: new Set()
  }
  const codeExecutor = makeCodeExecutor({
    activeTimeoutMs: 30_000,
    memoryLimitBytes: 64 * 1024 * 1024,
    maxStackSizeBytes: 1024 * 1024
  })
  const browserProvider = initializeAutomationProvider(
    "Browser Use",
    config.makeBrowserProvider ?? (() => makeBrowserUseProvider(config.dataDir, config.db)),
    unavailableBrowserProvider
  )
  const computerProvider = initializeAutomationProvider(
    "Computer Use",
    config.makeComputerProvider ?? (() => makeComputerUseProvider(config.dataDir)),
    unavailableComputerProvider
  )
  const selfMachine = config.machine ?? { id: selfServerId, name: hostname() }
  const turnClientIds = new Map<string, string>()
  const codevisorProvider = makeCodevisorProvider(
    () => state.gatewayBaseUrl,
    () => run(config.db.getOrCreateConnectionToken),
    {
      currentContext: async ({ sessionId }) => {
        const session = await run(config.db.getSessionSummary(sessionId)).catch(() => undefined)
        const parentSessionId = (session as { readonly parentSessionId?: unknown } | undefined)
          ?.parentSessionId
        const workspaceId = session?.workspaceId
        const worktreeName = session?.worktreeName
        const clientId = turnClientIds.get(sessionId)
        return {
          machine: selfMachine,
          ...(workspaceId === undefined ? {} : { workspaceId }),
          ...(worktreeName === undefined ? {} : { worktreeName }),
          ...(typeof parentSessionId === "string" ? { parentSessionId } : {}),
          ...(clientId === undefined ? {} : { clientId })
        }
      }
    }
  )
  const automationUse = makeAutomationUse()
  const automationProviders = new Map<string, AutomationToolProvider>([
    [browserProvider.id, automationUse.track(browserProvider)],
    [computerProvider.id, automationUse.track(computerProvider)],
    [codevisorProvider.id, codevisorProvider]
  ])
  const extensionFlowSupported = config.serverKind !== "remote"
  const browserSetupBroker = makeBrowserSetupBroker(browserProvider)
  const builtinProviderState = (
    id: BuiltinMcpId,
    enabled: boolean
  ): { readonly connectionState: McpConnectionState; readonly detail?: string } => {
    if (!enabled) return { connectionState: "disconnected" }
    if (id === "codevisor") return { connectionState: "connected" }
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
  const builtinsReady = Promise.all(
    BUILTIN_MCP_SERVERS.map(async (builtin) => {
      const provider = automationProviders.get(builtin.id)!
      const existing = await run(config.db.getMcpServer(builtin.id))
      if (existing !== undefined) {
        if (existing.kind !== builtin.kind) {
          throw new Error(`Reserved built-in MCP id is already in use: ${builtin.id}`)
        }
        const providerState = builtinProviderState(builtin.id, existing.enabled)
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
            connectionState: providerState.connectionState,
            toolCount: provider.tools.length,
            ...(providerState.detail === undefined ? {} : { detail: providerState.detail }),
            ...(existing.secretCipher === undefined ? {} : { secretCipher: existing.secretCipher })
          })
        )
      }
      const providerState = builtinProviderState(builtin.id, true)
      return run(
        config.db.saveMcpServer({
          ...builtin,
          transport: "stdio",
          args: [],
          enabled: true,
          authType: "none",
          connectionState: providerState.connectionState,
          toolCount: provider.tools.length,
          ...(providerState.detail === undefined ? {} : { detail: providerState.detail })
        })
      )
    })
  )
    .then(() => undefined)
    .catch((cause: unknown) => {
      reportBackgroundFailure("Built-in MCP initialization failed", cause)
    })

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
      headerNames: Object.keys(stored.headers ?? {}).toSorted((left, right) =>
        left.localeCompare(right)
      ),
      environmentNames: Object.keys(stored.env ?? {}).toSorted((left, right) =>
        left.localeCompare(right)
      )
    }
  }

  const saveRecord = async (
    server: McpServerRecord,
    patch: Partial<McpServerRecord> = {}
  ): Promise<McpServerRecord> => {
    const url = patch.url ?? server.url
    const command = patch.command ?? server.command
    const oauthScope = patch.oauthScope ?? server.oauthScope
    const detail = patch.detail
    const secretCipher = patch.secretCipher ?? server.secretCipher
    const saved = await run(
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
        /* v8 ignore next */
        connectionState: patch.connectionState ?? server.connectionState,
        toolCount: patch.toolCount ?? server.toolCount,
        ...(detail === undefined ? {} : { detail }),
        /* v8 ignore next */
        ...(secretCipher === undefined ? {} : { secretCipher })
      })
    )
    if (patch.secretCipher !== undefined || visibleSignature(saved) !== visibleSignature(server)) {
      emitServerChanged(saved.id)
    }
    return saved
  }

  const refreshBuiltinProviderStates = async (): Promise<void> => {
    await builtinsReady
    for (const builtin of BUILTIN_MCP_SERVERS) {
      const current = await record(builtin.id)
      const providerState = builtinProviderState(builtin.id, current.enabled)
      if (
        builtin.id === "computer" &&
        current.connectionState === "unavailable" &&
        providerState.connectionState === "connected" &&
        current.detail !== undefined &&
        current.detail !== "Open the native Codevisor app to use Computer Use"
      ) {
        continue
      }
      if (
        current.connectionState === providerState.connectionState &&
        current.detail === providerState.detail &&
        current.toolCount === automationProviders.get(builtin.id)!.tools.length
      ) {
        continue
      }
      await saveRecord(current, {
        connectionState: providerState.connectionState,
        toolCount: automationProviders.get(builtin.id)!.tools.length,
        ...(providerState.detail === undefined ? {} : { detail: providerState.detail })
      })
    }
  }

  /* v8 ignore start */
  const replaceSecrets = async (
    id: string,
    mutate: (current: StoredSecrets) => StoredSecrets
  ): Promise<McpServerRecord> => {
    const current = await record(id)
    return saveRecord(current, { secretCipher: encryptSecrets(key, mutate(secrets(current))) })
  }

  const closeConnection = async (id: string): Promise<void> => {
    const existing = connections.get(id)
    connections.delete(id)
    connectionLocks.delete(id)
    if (existing !== undefined) await existing.close().catch(() => undefined)
  }

  const callbackUrl = (): string =>
    new URL("/v1/mcps/oauth/callback", state.oauthBaseUrl).toString()
  /* v8 ignore stop */

  return {
    automationProviders,
    automationUse,
    browserProvider,
    browserSetupBroker,
    builtinProviderState,
    builtinsReady,
    callbackUrl,
    changeListeners,
    closeConnection,
    codeExecutor,
    computerProvider,
    config,
    connectionLocks,
    connections,
    emitCredentialsRotated,
    emitServerChanged,
    extensionFlowSupported,
    gatewayBearerToken,
    gateways,
    key,
    publicServer,
    record,
    refreshBuiltinProviderStates,
    refreshLocks,
    refreshRetryAttempts,
    refreshTimers,
    replaceSecrets,
    rotationListeners,
    saveRecord,
    secrets,
    selfMachine,
    selfServerId,
    sessionGatewayIds,
    state,
    turnClientIds
  }
}

export type McpManagerCore = ReturnType<typeof makeMcpManagerCore>
