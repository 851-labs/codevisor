import type {
  CreateMcpServerRequest,
  McpAuthDetection,
  McpServer,
  McpTool,
  UpdateMcpServerRequest
} from "@codevisor/api"
import type { CodevisorDatabaseService, McpServerRecord } from "@codevisor/db"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import {
  auth,
  discoverOAuthProtectedResourceMetadata,
  type OAuthClientProvider,
  type OAuthDiscoveryState
} from "@modelcontextprotocol/sdk/client/auth.js"
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js"
import {
  McpServer as McpSdkServer,
  type RegisteredTool
} from "@modelcontextprotocol/sdk/server/mcp.js"
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js"
import type {
  OAuthClientInformationMixed,
  OAuthClientMetadata,
  OAuthTokens
} from "@modelcontextprotocol/sdk/shared/auth.js"
import {
  type CallToolResult,
  isInitializeRequest,
  type JSONRPCMessage,
  JSONRPCMessageSchema,
  type Tool
} from "@modelcontextprotocol/sdk/types.js"
import type { Transport, TransportSendOptions } from "@modelcontextprotocol/sdk/shared/transport.js"
import {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomBytes,
  randomUUID,
  timingSafeEqual
} from "node:crypto"
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"
import { join } from "node:path"
import { Effect } from "effect"
import { z } from "zod"
import { makeQuickJsExecutor } from "@executor-js/runtime-quickjs"

interface StoredOAuth {
  readonly clientInformation?: OAuthClientInformationMixed | undefined
  readonly tokens?: OAuthTokens | undefined
  readonly tokensSavedAt?: number | undefined
  readonly codeVerifier?: string | undefined
  readonly discoveryState?: OAuthDiscoveryState | undefined
  readonly state?: string | undefined
  readonly redirectUrl?: string | undefined
  readonly configuredClientId?: string | undefined
  readonly configuredClientSecret?: string | undefined
}

interface StoredSecrets {
  readonly env?: Record<string, string> | undefined
  readonly headers?: Record<string, string> | undefined
  readonly bearerToken?: string | undefined
  readonly oauth?: StoredOAuth | undefined
}

interface UpstreamConnection {
  readonly client: Client
  readonly close: () => Promise<void>
  tools: ReadonlyArray<Tool>
}

interface SandboxExecuteResult {
  readonly result: unknown
  readonly output?: ReadonlyArray<unknown>
  readonly error?: string
  readonly logs?: ReadonlyArray<string>
}

/// One live MCP connection to a gateway. Harnesses may connect more than
/// once per Codevisor session: codex 0.145+ tears down and re-initializes
/// its MCP connections on mid-session events (account changes, plugin
/// changes), so a gateway must accept fresh `initialize` handshakes for as
/// long as the session lives — a single stateful transport (the previous
/// design) rejects the redial and the harness silently drops every tool.
interface GatewayConnection {
  readonly server: McpSdkServer
  readonly transport: StreamableHTTPServerTransport
  readonly searchTool: RegisteredTool
  readonly runCodeTool: RegisteredTool
}

interface GatewayRuntime {
  readonly sessionId: string
  readonly projectId?: string | undefined
  /// Live connections keyed by MCP session id (assigned at initialize).
  readonly connections: Map<string, GatewayConnection>
  inventory: string
}

export interface ToolGatewayConfig {
  readonly name: string
  readonly url: string
  readonly bearerToken: string
}

export interface McpManager {
  readonly setBaseUrl: (url: string) => void
  readonly list: () => Promise<ReadonlyArray<McpServer>>
  readonly create: (request: CreateMcpServerRequest) => Promise<McpServer>
  readonly detectAuth: (url: string) => Promise<McpAuthDetection>
  readonly update: (id: string, request: UpdateMcpServerRequest) => Promise<McpServer>
  readonly remove: (id: string) => Promise<void>
  readonly tools: (id?: string) => Promise<ReadonlyArray<McpTool>>
  readonly connect: (id: string) => Promise<McpServer>
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
  readonly issueGateway: (sessionId: string, projectId?: string) => Promise<ToolGatewayConfig>
  readonly handleGatewayRequest: (
    request: IncomingMessage,
    response: ServerResponse
  ) => Promise<void>
  readonly close: () => Promise<void>
}

export interface McpManagerConfig {
  readonly db: CodevisorDatabaseService
  readonly dataDir: string
}

const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

/// Buffer and parse a JSON request body. The parsed value is handed to the
/// SDK transport (which accepts pre-parsed bodies), so consuming the stream
/// here is safe.
const readJsonBody = async (request: IncomingMessage): Promise<unknown> => {
  const chunks: Array<Buffer> = []
  // Without setEncoding, node HTTP request streams always yield Buffers.
  for await (const chunk of request) {
    chunks.push(chunk as Buffer)
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown
}

const errorMessage = (cause: unknown): string => {
  /* v8 ignore next -- SDK, database, HTTP, and runtime failures use Error instances. */
  if (cause instanceof Error) return cause.message
  /* v8 ignore next -- retained for defensive formatting of external throwables. */
  return String(cause)
}

const requireHttpUrl = (value: string | undefined): string => {
  if (value === undefined) throw new Error("An HTTP MCP server requires a URL")
  const url = new URL(value)
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new Error("MCP server URLs must use HTTP or HTTPS")
  }
  return url.toString()
}

const validateRequest = (
  request: Pick<
    CreateMcpServerRequest,
    | "transport"
    | "url"
    | "command"
    | "env"
    | "headers"
    | "authType"
    | "bearerToken"
    | "oauthScope"
    | "oauthClientId"
    | "oauthClientSecret"
  >
): void => {
  if (request.transport === "http") requireHttpUrl(request.url)
  if (request.transport === "http" && request.env !== undefined) {
    throw new Error("Environment variables are only supported for stdio MCP servers")
  }
  if (request.transport === "stdio" && request.headers !== undefined) {
    throw new Error("HTTP headers are only supported for HTTP MCP servers")
  }
  if (
    request.transport === "stdio" &&
    request.authType !== undefined &&
    request.authType !== "none"
  ) {
    throw new Error("Authorization is only supported for HTTP MCP servers")
  }
  if (
    request.transport === "stdio" &&
    (request.bearerToken !== undefined ||
      request.oauthScope !== undefined ||
      request.oauthClientId !== undefined ||
      request.oauthClientSecret !== undefined)
  ) {
    throw new Error("Authorization credentials are only supported for HTTP MCP servers")
  }
  if (request.transport === "stdio" && request.command?.trim().length === 0) {
    throw new Error("A stdio MCP server requires a command")
  }
  if (request.transport === "stdio" && request.command === undefined) {
    throw new Error("A stdio MCP server requires a command")
  }
}

const suggestedMcpName = (url: URL): string => {
  const labels = url.hostname.split(".").filter(Boolean)
  const candidate = labels.find((label) => !["www", "mcp", "api"].includes(label)) ?? labels[0]
  /* v8 ignore next -- a valid HTTP(S) URL always has at least one hostname label. */
  if (candidate === undefined) return "MCP Server"
  return candidate
    .split(/[-_]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ")
}

const MAX_TIMER_DELAY_MS = 2_147_000_000

export const boundedMcpTimerDelay = (delay: number): number =>
  Math.min(Math.max(1, delay), MAX_TIMER_DELAY_MS)

const messageFromSseBlock = (block: string): unknown | undefined => {
  const data = block
    .split(/\r?\n/)
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).trimStart())
    .join("\n")
  if (data.length === 0) return undefined
  try {
    return JSON.parse(data) as unknown
  } catch {
    return undefined
  }
}

export class NodeStreamableHttpTransport implements Transport {
  onclose?: () => void
  onerror?: (error: Error) => void
  onmessage?: <T extends JSONRPCMessage>(message: T) => void
  sessionId?: string

  private controller: AbortController | undefined
  private protocolVersion: string | undefined

  constructor(
    private readonly url: URL,
    private readonly accessToken?: string,
    private readonly customHeaders: Readonly<Record<string, string>> = {}
  ) {}

  setProtocolVersion(version: string): void {
    this.protocolVersion = version
  }

  async start(): Promise<void> {
    if (this.controller !== undefined) throw new Error("MCP HTTP transport is already started")
    this.controller = new AbortController()
  }

  async send(message: JSONRPCMessage, _options?: TransportSendOptions): Promise<void> {
    const response = await fetch(this.url, {
      method: "POST",
      headers: this.headers("application/json, text/event-stream"),
      body: JSON.stringify(message),
      signal: this.controller?.signal ?? null
    })
    const sessionId = response.headers.get("mcp-session-id")
    if (sessionId !== null) this.sessionId = sessionId
    if (!response.ok) {
      /* v8 ignore next -- standard Fetch responses expose a readable error body. */
      const detail = await response.text().catch(() => response.statusText)
      throw new Error(`Streamable HTTP error ${response.status}: ${detail}`)
    }
    if (response.status === 202) {
      await response.body?.cancel()
      return
    }
    /* v8 ignore next -- Fetch normalizes a content type for non-empty response bodies. */
    const contentType = response.headers.get("content-type") ?? ""
    if (contentType.includes("application/json")) {
      this.dispatch(await response.json())
      return
    }
    if (contentType.includes("text/event-stream")) {
      const requestId = "id" in message ? message.id : undefined
      await this.consumeSse(response, requestId)
      return
    }
    await response.body?.cancel()
    throw new Error(`Unexpected MCP response content type: ${contentType}`)
  }

  async close(): Promise<void> {
    this.controller?.abort()
    this.controller = undefined
    this.onclose?.()
  }

  private headers(accept: string): Headers {
    const headers = new Headers(this.customHeaders)
    headers.set("accept", accept)
    headers.set("content-type", "application/json")
    if (this.accessToken !== undefined) {
      headers.set("authorization", `Bearer ${this.accessToken}`)
    }
    if (this.sessionId !== undefined) headers.set("mcp-session-id", this.sessionId)
    if (this.protocolVersion !== undefined) {
      headers.set("mcp-protocol-version", this.protocolVersion)
    }
    return headers
  }

  private dispatch(decoded: unknown): void {
    const messages = Array.isArray(decoded) ? decoded : [decoded]
    for (const message of messages) {
      this.onmessage?.(JSONRPCMessageSchema.parse(message))
    }
  }

  private async consumeSse(response: Response, stopAfterId?: string | number): Promise<void> {
    if (response.body === null) return
    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    let pending = ""
    while (true) {
      const chunk = await reader.read()
      pending += decoder.decode(chunk.value, { stream: !chunk.done })
      const blocks = pending.split(/\r?\n\r?\n/)
      /* v8 ignore next -- split always leaves a final string while the stream is open. */
      pending = chunk.done ? "" : (blocks.pop() ?? "")
      for (const block of blocks) {
        const decoded = messageFromSseBlock(block)
        if (decoded === undefined) {
          console.error(`Unable to decode MCP SSE event (${block.length} characters)`)
          continue
        }
        this.dispatch(decoded)
        /* v8 ignore next -- batched SSE responses are optional and JSON batches are covered above. */
        const messages = Array.isArray(decoded) ? decoded : [decoded]
        if (
          stopAfterId !== undefined &&
          messages.some(
            (message) =>
              typeof message === "object" &&
              message !== null &&
              "id" in message &&
              (message as { id?: unknown }).id === stopAfterId
          )
        ) {
          /* v8 ignore next -- cancellation is best-effort after the matching response arrived. */
          await reader.cancel().catch(() => undefined)
          return
        }
      }
      if (chunk.done) return
    }
  }
}

const loadEncryptionKey = (dataDir: string): Buffer => {
  const configured = process.env.CODEVISOR_MCP_SECRET_KEY ?? process.env.HERDMAN_MCP_SECRET_KEY
  if (configured !== undefined) {
    const key = Buffer.from(configured, "base64")
    if (key.length !== 32) throw new Error("CODEVISOR_MCP_SECRET_KEY must be 32 bytes in base64")
    return key
  }
  mkdirSync(dataDir, { recursive: true, mode: 0o700 })
  const path = join(dataDir, "mcp-secret-key")
  if (!existsSync(path)) {
    writeFileSync(path, randomBytes(32), { mode: 0o600 })
  }
  chmodSync(path, 0o600)
  const key = readFileSync(path)
  if (key.length !== 32) throw new Error(`Invalid MCP secret key at ${path}`)
  return key
}

const encryptSecrets = (key: Buffer, value: StoredSecrets): string => {
  const iv = randomBytes(12)
  const cipher = createCipheriv("aes-256-gcm", key, iv)
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(value), "utf8"), cipher.final()])
  return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString("base64")
}

const decryptSecrets = (key: Buffer, value: string | undefined): StoredSecrets => {
  if (value === undefined) return {}
  const encoded = Buffer.from(value, "base64")
  if (encoded.length < 29) throw new Error("Invalid encrypted MCP credentials")
  const decipher = createDecipheriv("aes-256-gcm", key, encoded.subarray(0, 12))
  decipher.setAuthTag(encoded.subarray(12, 28))
  return JSON.parse(
    Buffer.concat([decipher.update(encoded.subarray(28)), decipher.final()]).toString("utf8")
  ) as StoredSecrets
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
  const gateways = new Map<string, GatewayRuntime>()
  const sessionGatewayIds = new Map<string, string>()
  let gatewayBaseUrl = "http://127.0.0.1:49361"
  let oauthBaseUrl = gatewayBaseUrl
  const codeExecutor = makeQuickJsExecutor({
    timeoutMs: 30_000,
    memoryLimitBytes: 64 * 1024 * 1024,
    maxStackSizeBytes: 1024 * 1024
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

  /* v8 ignore start -- these helpers are used exclusively by the live OAuth adapter below. */
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

  const callbackUrl = (): string => new URL("/v1/mcps/oauth/callback", oauthBaseUrl).toString()
  /* v8 ignore stop */

  /* v8 ignore start -- the OAuth SDK callback contract, browser redirect, token refresh, and
   * retry timers are exercised against live OAuth MCP providers in the macOS integration flow. */
  const oauthProvider = (
    serverId: string,
    savedRedirectUrl?: string
  ): OAuthClientProvider & { authorizationUrl?: URL } => {
    const redirectUrl = savedRedirectUrl ?? callbackUrl()
    const provider: OAuthClientProvider & { authorizationUrl?: URL } = {
      redirectUrl,
      get clientMetadata(): OAuthClientMetadata {
        return {
          client_name: "Codevisor",
          redirect_uris: [redirectUrl],
          grant_types: ["authorization_code", "refresh_token"],
          response_types: ["code"],
          token_endpoint_auth_method: "none",
          scope: undefined
        }
      },
      state: async () => secrets(await record(serverId)).oauth?.state ?? "",
      clientInformation: async () => {
        const oauth = secrets(await record(serverId)).oauth
        if (oauth?.clientInformation !== undefined) return oauth.clientInformation
        if (oauth?.configuredClientId === undefined) return undefined
        return {
          client_id: oauth.configuredClientId,
          ...(oauth.configuredClientSecret === undefined
            ? {}
            : { client_secret: oauth.configuredClientSecret })
        }
      },
      saveClientInformation: async (clientInformation) => {
        await replaceSecrets(serverId, (value) => ({
          ...value,
          oauth: { ...value.oauth, clientInformation }
        }))
      },
      tokens: async () => secrets(await record(serverId)).oauth?.tokens,
      saveTokens: async (tokens) => {
        const saved = await replaceSecrets(serverId, (value) => ({
          ...value,
          oauth: { ...value.oauth, tokens, tokensSavedAt: Date.now() }
        }))
        scheduleRefresh(saved, tokens)
      },
      redirectToAuthorization: (authorizationUrl) => {
        provider.authorizationUrl = authorizationUrl
      },
      saveCodeVerifier: async (codeVerifier) => {
        await replaceSecrets(serverId, (value) => ({
          ...value,
          oauth: { ...value.oauth, codeVerifier }
        }))
      },
      codeVerifier: async () => {
        const value = secrets(await record(serverId)).oauth?.codeVerifier
        if (value === undefined) throw new Error("OAuth code verifier is missing")
        return value
      },
      saveDiscoveryState: async (discoveryState) => {
        await replaceSecrets(serverId, (value) => ({
          ...value,
          oauth: { ...value.oauth, discoveryState }
        }))
      },
      discoveryState: async () => secrets(await record(serverId)).oauth?.discoveryState,
      invalidateCredentials: async (scope) => {
        await replaceSecrets(serverId, (value) => {
          if (scope === "all") return { ...value, oauth: undefined }
          if (scope === "tokens") return { ...value, oauth: { ...value.oauth, tokens: undefined } }
          if (scope === "verifier") {
            return { ...value, oauth: { ...value.oauth, codeVerifier: undefined } }
          }
          if (scope === "discovery") {
            return { ...value, oauth: { ...value.oauth, discoveryState: undefined } }
          }
          return { ...value, oauth: { ...value.oauth, clientInformation: undefined } }
        })
      }
    }
    return provider
  }

  const scheduleRefresh = (server: McpServerRecord, tokens: OAuthTokens): void => {
    const existing = refreshTimers.get(server.id)
    if (existing !== undefined) clearTimeout(existing)
    if (tokens.refresh_token === undefined || tokens.expires_in === undefined) return
    const savedAt = secrets(server).oauth?.tokensSavedAt ?? Date.now()
    const elapsed = Math.max(0, Date.now() - savedAt)
    const jitter = Math.floor(Math.random() * 30_000)
    const delay = Math.max(1_000, tokens.expires_in * 1000 - elapsed - 120_000 - jitter)
    const timerDelay = boundedMcpTimerDelay(delay)
    const timer = setTimeout(() => {
      if (delay <= MAX_TIMER_DELAY_MS) {
        void refreshOAuth(server.id)
        return
      }
      void record(server.id)
        .then((current) => {
          const currentTokens = secrets(current).oauth?.tokens
          if (currentTokens !== undefined) scheduleRefresh(current, currentTokens)
        })
        .catch(() => undefined)
    }, timerDelay)
    timer.unref?.()
    refreshTimers.set(server.id, timer)
  }

  const scheduleRefreshRetry = (id: string): void => {
    const attempt = (refreshRetryAttempts.get(id) ?? 0) + 1
    refreshRetryAttempts.set(id, attempt)
    const delay = Math.min(15 * 60_000, 30_000 * 2 ** Math.min(attempt - 1, 5))
    const timer = setTimeout(() => void refreshOAuth(id), delay + Math.random() * 10_000)
    timer.unref?.()
    refreshTimers.set(id, timer)
  }

  const performRefreshOAuth = async (id: string): Promise<void> => {
    const current = await record(id)
    if (current.authType !== "oauth") return
    try {
      const result = await auth(oauthProvider(id, secrets(current).oauth?.redirectUrl), {
        serverUrl: requireHttpUrl(current.url),
        ...(current.oauthScope === undefined ? {} : { scope: current.oauthScope })
      })
      if (result !== "AUTHORIZED") throw new Error("OAuth reauthorization is required")
      refreshRetryAttempts.delete(id)
      const updated = await record(id)
      await saveRecord(updated, { enabled: true, connectionState: "connected", detail: undefined })
      await closeConnection(id)
      await refreshGatewayInventories()
    } catch (cause) {
      const updated = await record(id)
      await saveRecord(updated, {
        enabled: false,
        connectionState: "expired",
        detail: `Authorization refresh failed: ${errorMessage(cause)}`
      })
      await refreshGatewayInventories()
      scheduleRefreshRetry(id)
    }
  }

  const refreshOAuth = async (id: string): Promise<void> => {
    const existing = refreshLocks.get(id)
    if (existing !== undefined) return existing
    const refreshing = performRefreshOAuth(id).finally(() => refreshLocks.delete(id))
    refreshLocks.set(id, refreshing)
    return refreshing
  }
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

  const integrationInventory = async (projectId?: string, sessionId?: string): Promise<string> => {
    const names = (await run(config.db.resolveMcpServers(projectId, sessionId)))
      .filter((server) => server.enabled)
      .map((server) => server.name.trim())
      .filter((name) => name.length > 0)
      .sort((left, right) => left.localeCompare(right))
    if (names.length === 0) return "Available integrations: none."
    return ["Available integrations through Codevisor:", ...names.map((name) => `- ${name}`)].join(
      "\n"
    )
  }

  const searchToolDescription = (inventory: string): string =>
    [
      "Entry point for every integration connected through Codevisor. When the user asks to use a named service or external system, call this tool first even if no direct connector is visible. Search returns exact tool paths and the next steps; continue with describe and execute instead of stopping after discovery.",
      inventory
    ].join("\n\n")

  const runCodeToolDescription = (inventory: string): string =>
    [
      "Run sandboxed JavaScript or TypeScript that discovers and composes enabled integration tools. The isolate has no filesystem, network, process environment, or credentials.",
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
      if (!server.enabled && options.allowDisabled !== true) {
        throw new Error(`${server.name} is disabled`)
      }
      /* v8 ignore next -- preserveState is reserved for the live OAuth validation path. */
      if (options.preserveState !== true) {
        await saveRecord(server, { connectionState: "connecting", detail: undefined })
      }
      const stored = secrets(server)
      const client = new Client({ name: "Codevisor", version: "0.1.0" }, { capabilities: {} })
      /* v8 ignore next -- OAuth access tokens are supplied by the live OAuth adapter above. */
      const accessToken = stored.bearerToken ?? stored.oauth?.tokens?.access_token
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

  /* v8 ignore start -- completion validation requires a live OAuth provider and upstream MCP. */
  const validateOAuthConnection = async (id: string): Promise<void> => {
    try {
      await connectUpstream(id, { allowDisabled: true, preserveState: true })
      await saveRecord(await record(id), {
        enabled: true,
        connectionState: "connected",
        detail: undefined
      })
    } catch (cause) {
      await closeConnection(id)
      const current = await record(id)
      await saveRecord(current, {
        enabled: false,
        connectionState: "needsAuthorization",
        toolCount: 0,
        detail: undefined
      })
      console.error(`OAuth validation failed for ${current.name}: ${errorMessage(cause)}`)
    }
    await refreshGatewayInventories()
  }
  /* v8 ignore stop */

  const allTools = async (
    projectId?: string,
    sessionId?: string
  ): Promise<ReadonlyArray<{ server: McpServerRecord; tool: Tool }>> => {
    const enabled = (await run(config.db.resolveMcpServers(projectId, sessionId))).filter(
      (server) => server.enabled
    )
    const results = await Promise.allSettled(
      enabled.map(async (server) => ({ server, connection: await connectUpstream(server.id) }))
    )
    return results.flatMap((result) =>
      result.status === "fulfilled"
        ? result.value.connection.tools.map((tool) => ({ server: result.value.server, tool }))
        : []
    )
  }

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
    const allowed = (await run(config.db.resolveMcpServers(projectId, sessionId))).some(
      (candidate) => candidate.id === serverId && candidate.enabled
    )
    if (!allowed) throw new Error("Tool server is disabled for this session")
    const definition = (await connectUpstream(serverId)).tools.find(
      (candidate) => candidate.name === toolName
    )
    if (definition === undefined) throw new Error(`Tool not found: ${path}`)
    return definition
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
    const sdkServer = new McpSdkServer(
      { name: "Codevisor Tool Gateway", version: "0.1.0" },
      {
        instructions: [
          "Codevisor provides access to the user's enabled integrations. Use search to discover tools, describe to inspect a schema, and execute to call it. Do not conclude that an integration is unavailable before searching Codevisor. Tool calls are approved by default.",
          inventory
        ].join("\n\n")
      }
    )
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
        description: "Return the full schema for one enabled MCP tool.",
        inputSchema: { server: z.string(), tool: z.string() }
      },
      async ({ server, tool }) => {
        const allowed = (await run(config.db.resolveMcpServers(projectId, sessionId))).some(
          (candidate) => candidate.id === server && candidate.enabled
        )
        if (!allowed) {
          return {
            isError: true,
            content: [{ type: "text" as const, text: "Tool server is disabled for this session" }]
          }
        }
        const connection = await connectUpstream(server)
        const definition = connection.tools.find((candidate) => candidate.name === tool)
        if (definition === undefined) {
          return { isError: true, content: [{ type: "text" as const, text: "Tool not found" }] }
        }
        return { content: [{ type: "text" as const, text: JSON.stringify(definition) }] }
      }
    )
    sdkServer.registerTool(
      "execute",
      {
        description: "Execute one enabled MCP tool with JSON arguments.",
        inputSchema: {
          server: z.string(),
          tool: z.string(),
          arguments: z.record(z.string(), z.unknown()).default({})
        }
      },
      async ({ server, tool, arguments: args }): Promise<CallToolResult> => {
        const installed = await record(server)
        const allowed = (await run(config.db.resolveMcpServers(projectId, sessionId))).some(
          (candidate) => candidate.id === server && candidate.enabled
        )
        if (!installed.enabled || !allowed) {
          return {
            isError: true,
            content: [{ type: "text", text: `${installed.name} is disabled` }]
          }
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
      async ({ code }) => {
        const result = (await Effect.runPromise(
          codeExecutor.execute(code, {
            invoke: ({ path, args }: { path: string; args: unknown }) =>
              Effect.tryPromise({
                try: async () => {
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
                  const installed = await record(serverId)
                  const allowed = (
                    await run(config.db.resolveMcpServers(projectId, sessionId))
                  ).some((candidate) => candidate.id === serverId && candidate.enabled)
                  if (!installed.enabled || !allowed) {
                    throw new Error(`${installed.name} is disabled for this session`)
                  }
                  const connection = await connectUpstream(serverId)
                  return connection.client.callTool({
                    name: toolName,
                    arguments:
                      typeof args === "object" && args !== null
                        ? (args as Record<string, unknown>)
                        : {}
                  })
                },
                catch: (cause) => new Error(errorMessage(cause))
              })
          }) as never
        )) as SandboxExecuteResult
        if (result.error !== undefined) {
          return { isError: true, content: [{ type: "text" as const, text: result.error }] }
        }
        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                result: result.result,
                output: result.output,
                logs: result.logs
              })
            }
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

  const manager: McpManager = {
    setBaseUrl: (url) => {
      const parsed = new URL(url)
      gatewayBaseUrl = `${parsed.protocol}//127.0.0.1:${parsed.port}`
      oauthBaseUrl = gatewayBaseUrl
    },
    list: async () => (await run(config.db.listMcpServers)).map(publicServer),
    detectAuth,
    create: async (request) => {
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
        ...(request.bearerToken === undefined ? {} : { bearerToken: request.bearerToken }),
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
      const current = await record(id)
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
    remove: async (id) => {
      await closeConnection(id)
      const timer = refreshTimers.get(id)
      /* v8 ignore next -- timers only exist for the live OAuth refresh adapter. */
      if (timer !== undefined) clearTimeout(timer)
      refreshTimers.delete(id)
      await run(config.db.deleteMcpServer(id))
      await refreshGatewayInventories()
    },
    tools: async (id) => {
      const selected = id === undefined ? undefined : await record(id)
      const pairs =
        id === undefined
          ? await allTools()
          : (await connectUpstream(id)).tools.map((tool) => ({ server: selected!, tool }))
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
        void validateOAuthConnection(id)
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
      void validateOAuthConnection(id)
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
    resolved: async (projectId, sessionId) =>
      (await run(config.db.resolveMcpServers(projectId, sessionId))).map(publicServer),
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
    issueGateway: async (sessionId, projectId) => {
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
      /* v8 ignore next -- timers only exist for the live OAuth refresh adapter. */
      for (const timer of refreshTimers.values()) clearTimeout(timer)
      await Promise.all([...connections.keys()].map(closeConnection))
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
  void run(config.db.listMcpServers).then((servers) => {
    for (const server of servers) {
      const oauth = secrets(server).oauth
      if (oauth?.tokens !== undefined) scheduleRefresh(server, oauth.tokens)
    }
  })
  /* v8 ignore stop */

  return manager
}
