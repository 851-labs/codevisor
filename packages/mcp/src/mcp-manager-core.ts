import type { McpConnectionState, McpServer } from "@codevisor/api"
import type { McpServerRecord } from "@codevisor/db"
import { createHash } from "node:crypto"
import {
  makeBrowserSetupBroker,
  makeBrowserUseProvider,
  makeCodeExecutor,
  makeCodevisorProvider,
  makeComputerUseProvider,
  type AutomationToolProvider
} from "@codevisor/automation"
import {
  BUILTIN_MCP_SERVERS,
  initializeAutomationProvider,
  managedAutomationSkills,
  unavailableBrowserProvider,
  unavailableComputerProvider
} from "./mcp-automation-builtins.js"
import type { GatewayRuntime } from "./mcp-gateway.js"
import type { McpManagerConfig } from "./mcp-manager-types.js"
import {
  decryptSecrets,
  encryptSecrets,
  loadEncryptionKey,
  type StoredSecrets
} from "./mcp-secret-store.js"
import { reportBackgroundFailure, run, type UpstreamConnection } from "./mcp-support.js"

/// Manager state that operations reassign after construction: the gateway
/// and OAuth base URLs follow the server's bound port, and the local
/// suppression set follows the config plane.
export interface McpManagerState {
  gatewayBaseUrl: string
  oauthBaseUrl: string
  locallySuppressed: ReadonlySet<string>
}

const DEFAULT_GATEWAY_BASE_URL = "http://127.0.0.1:49361"

/// Everything the operation modules share: the encryption key, connection
/// and gateway registries, the built-in automation providers, and the
/// record helpers that keep persisted connection state consistent.
export const makeMcpManagerCore = (config: McpManagerConfig) => {
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
  // Observers of a server record's visible state (the server publishes
  // these as mcp.updated events so settings views follow connection
  // transitions live instead of polling).
  const changeListeners = new Set<(id: string) => void>()
  const emitServerChanged = (id: string): void => {
    for (const listener of [...changeListeners]) listener(id)
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
    config.makeBrowserProvider ?? (() => makeBrowserUseProvider(config.dataDir)),
    unavailableBrowserProvider
  )
  const computerProvider = initializeAutomationProvider(
    "Computer Use",
    config.makeComputerProvider ?? (() => makeComputerUseProvider(config.dataDir)),
    unavailableComputerProvider
  )
  const codevisorProvider = makeCodevisorProvider(
    () => state.gatewayBaseUrl,
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
            .filter((record) => record.enabled && !state.locallySuppressed.has(record.name))
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

  /// The fields a change listener cares about: what a settings row renders.
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
        /* v8 ignore next -- every internal save transition supplies its resulting connection state. */
        connectionState: patch.connectionState ?? server.connectionState,
        toolCount: patch.toolCount ?? server.toolCount,
        ...(detail === undefined ? {} : { detail }),
        /* v8 ignore next -- manager-owned records always have an encrypted secret payload. */
        ...(secretCipher === undefined ? {} : { secretCipher })
      })
    )
    // Secret rewrites change what the row shows (header/env names) even
    // though the ciphertext itself is never compared.
    if (patch.secretCipher !== undefined || visibleSignature(saved) !== visibleSignature(server)) {
      emitServerChanged(saved.id)
    }
    return saved
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

  /* v8 ignore start -- these helpers are used exclusively by the live OAuth adapter. */
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
    browserProvider,
    browserSetupBroker,
    builtinProviderState,
    builtinsReady,
    callbackUrl,
    changeListeners,
    closeConnection,
    codeExecutor,
    codevisorProvider,
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
    selfServerId,
    sessionGatewayIds,
    state,
    syncManagedAutomationSkillsFromDb
  }
}

export type McpManagerCore = ReturnType<typeof makeMcpManagerCore>
