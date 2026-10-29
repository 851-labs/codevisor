import { createHash } from "node:crypto"
import { createCipheriv, randomBytes } from "node:crypto"
import { mkdtempSync, readFileSync } from "node:fs"
import { createServer, type IncomingMessage, type ServerResponse } from "node:http"
import type { Server } from "node:http"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { coordinateCredential, type CredentialRecord } from "@codevisor/api"
import type { CredentialCoordinator } from "@codevisor/harness-manager"
import type { McpOAuthClock } from "@codevisor/mcp"
import { Effect } from "effect"
import { onTestFinished } from "vitest"

import { tempDirs, type makeServices } from "../test-support.js"
import { isRecord } from "../unknown-values.js"
import { mcpCredentialVault } from "./shared-account-storage.js"

const listen = async (server: Server): Promise<string> => {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  onTestFinished(
    () =>
      new Promise<void>((resolve, reject) => {
        server.closeAllConnections()
        server.close((error) => (error === undefined ? resolve() : reject(error)))
      })
  )
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("Missing test port")
  return `http://127.0.0.1:${address.port}`
}

export interface ManualOAuthClock extends McpOAuthClock {
  readonly advance: (ms: number) => void
  readonly sleep: (ms: number) => void
  readonly pendingDueTimes: () => ReadonlyArray<number>
  readonly scheduled: (at: number) => Promise<void>
}

export const manualOAuthClock = (start = Date.UTC(2026, 9, 20, 9)): ManualOAuthClock => {
  let current = start
  const pending = new Set<{ readonly at: number; readonly callback: () => void }>()
  const waiters = new Map<number, Array<() => void>>()
  return {
    now: () => current,
    setTimeout: (callback, delayMs) => {
      const timer = { at: current + delayMs, callback }
      pending.add(timer)
      for (const resolve of waiters.get(timer.at) ?? []) resolve()
      waiters.delete(timer.at)
      return () => pending.delete(timer)
    },
    scheduled: async (at) => {
      if ([...pending].some((timer) => timer.at === at)) return
      const scheduled = Promise.withResolvers<void>()
      waiters.set(at, [...(waiters.get(at) ?? []), scheduled.resolve])
      await scheduled.promise
    },
    advance: (ms) => {
      current += ms
      const due = [...pending]
        .filter((timer) => timer.at <= current)
        .toSorted((a, b) => a.at - b.at)
      for (const timer of due) {
        pending.delete(timer)
        timer.callback()
      }
    },
    pendingDueTimes: () => [...pending].map((timer) => timer.at).toSorted((a, b) => a - b),
    sleep: (ms) => {
      current += ms
      const shifted = Array.from(pending, (timer) => ({
        at: timer.at + ms,
        callback: timer.callback
      }))
      pending.clear()
      for (const timer of shifted) pending.add(timer)
    }
  }
}

interface Grant {
  readonly id: string
  revoked: boolean
}

interface IssuedRefreshToken {
  readonly grant: Grant
  spent: boolean
}

interface IssuedAccessToken {
  readonly grant: Grant
  readonly expiresAt: number
}

export interface RefreshAttempt {
  readonly refreshToken: string
  readonly outcome: "rotated" | "reused" | "revoked" | "unknown" | "unavailable"
}

const readBody = async (request: IncomingMessage): Promise<string> => {
  const chunks: Array<Buffer> = []
  for await (const chunk of request) {
    if (Buffer.isBuffer(chunk)) chunks.push(chunk)
  }
  return Buffer.concat(chunks).toString("utf8")
}

const json = (response: ServerResponse, status: number, body: unknown): void => {
  response.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" })
  response.end(JSON.stringify(body))
}

const rpcMessage = (body: string): { readonly id?: unknown; readonly method: string } => {
  const parsed: unknown = JSON.parse(body)
  if (!isRecord(parsed) || typeof parsed.method !== "string") throw new Error("Not JSON-RPC")
  return { id: parsed.id, method: parsed.method }
}

const registration = (body: string): Record<string, unknown> & { redirect_uris: string[] } => {
  const parsed: unknown = JSON.parse(body)
  if (!isRecord(parsed) || !Array.isArray(parsed.redirect_uris)) throw new Error("Bad registration")
  return { ...parsed, redirect_uris: parsed.redirect_uris.map(String) }
}

export const fakeOAuthMcpServer = async (
  clock: McpOAuthClock,
  accessTokenLifetimeSeconds = 3600,
  allowsRedirect: (redirectUri: string) => boolean = () => true
) => {
  let sequence = 0
  const next = (prefix: string): string => `${prefix}-${++sequence}`
  const grants: Array<Grant> = []
  const clients = new Map<string, ReadonlyArray<string>>()
  const codes = new Map<
    string,
    { readonly clientId: string; readonly redirectUri: string; readonly challenge: string }
  >()
  const refreshTokens = new Map<string, IssuedRefreshToken>()
  const accessTokens = new Map<string, IssuedAccessToken>()
  const refreshAttempts: Array<RefreshAttempt> = []
  const toolCalls: Array<{ readonly grant: string }> = []
  let unavailableRefreshes = 0
  let heldRefresh: Promise<void> | undefined
  let heldRefreshes = 0
  let unauthorizedResponses = 0
  const observers = new Set<() => void>()
  const notify = (): void => {
    for (const observer of Array.from(observers)) observer()
  }
  const until = async (predicate: () => boolean): Promise<void> => {
    while (!predicate()) {
      const changed = Promise.withResolvers<void>()
      observers.add(changed.resolve)
      try {
        if (predicate()) return
        await changed.promise
      } finally {
        observers.delete(changed.resolve)
      }
    }
  }

  const issue = (grant: Grant) => {
    const accessToken = next("access")
    const refreshToken = next("refresh")
    accessTokens.set(accessToken, {
      grant,
      expiresAt: clock.now() + accessTokenLifetimeSeconds * 1000
    })
    refreshTokens.set(refreshToken, { grant, spent: false })
    return {
      access_token: accessToken,
      refresh_token: refreshToken,
      token_type: "Bearer",
      expires_in: accessTokenLifetimeSeconds
    }
  }

  const tokenEndpoint = async (request: IncomingMessage, response: ServerResponse) => {
    const form = new URLSearchParams(await readBody(request))
    if (form.get("grant_type") === "authorization_code") {
      const code = codes.get(form.get("code") ?? "")
      codes.delete(form.get("code") ?? "")
      const verifier = form.get("code_verifier") ?? ""
      const challenge = createHash("sha256").update(verifier).digest("base64url")
      if (
        code === undefined ||
        code.challenge !== challenge ||
        code.clientId !== form.get("client_id") ||
        code.redirectUri !== form.get("redirect_uri")
      ) {
        json(response, 400, { error: "invalid_grant" })
        return
      }
      const grant = { id: next("grant"), revoked: false }
      grants.push(grant)
      json(response, 200, issue(grant))
      return
    }
    const presented = form.get("refresh_token") ?? ""
    if (heldRefresh !== undefined) {
      heldRefreshes += 1
      notify()
      await heldRefresh
    }
    if (unavailableRefreshes > 0) {
      unavailableRefreshes -= 1
      refreshAttempts.push({ refreshToken: presented, outcome: "unavailable" })
      notify()
      json(response, 503, { error: "temporarily_unavailable" })
      return
    }
    const issued = refreshTokens.get(presented)
    if (issued === undefined) {
      refreshAttempts.push({ refreshToken: presented, outcome: "unknown" })
      notify()
      json(response, 400, { error: "invalid_grant" })
      return
    }
    if (issued.grant.revoked) {
      refreshAttempts.push({ refreshToken: presented, outcome: "revoked" })
      notify()
      json(response, 400, { error: "invalid_grant", error_description: "Grant revoked" })
      return
    }
    if (issued.spent) {
      issued.grant.revoked = true
      refreshAttempts.push({ refreshToken: presented, outcome: "reused" })
      notify()
      json(response, 400, { error: "invalid_grant", error_description: "Refresh token reused" })
      return
    }
    issued.spent = true
    refreshAttempts.push({ refreshToken: presented, outcome: "rotated" })
    notify()
    json(response, 200, issue(issued.grant))
  }

  const resource = async (request: IncomingMessage, response: ServerResponse, base: string) => {
    const bearer = request.headers.authorization?.replace(/^Bearer /i, "") ?? ""
    const token = accessTokens.get(bearer)
    const body = await readBody(request)
    if (token === undefined || token.grant.revoked || clock.now() >= token.expiresAt) {
      unauthorizedResponses += 1
      notify()
      response.writeHead(401, {
        "www-authenticate": `Bearer resource_metadata="${base}/.well-known/oauth-protected-resource/mcp"`
      })
      response.end()
      return
    }
    const message = rpcMessage(body)
    if (message.id === undefined) {
      response.writeHead(202)
      response.end()
      return
    }
    let result: unknown
    if (message.method === "initialize") {
      result = {
        protocolVersion: "2025-11-25",
        capabilities: { tools: {} },
        serverInfo: { name: "fake-oauth-mcp", version: "1" }
      }
    } else if (message.method === "tools/list") {
      result = {
        tools: [{ name: "whoami", inputSchema: { type: "object", properties: {} } }]
      }
    } else {
      toolCalls.push({ grant: token.grant.id })
      notify()
      result = { content: [{ type: "text", text: token.grant.id }] }
    }
    json(response, 200, { jsonrpc: "2.0", id: message.id, result })
  }

  let base = ""
  const server = createServer((request, response) => {
    const path = new URL(request.url ?? "/", base).pathname
    const handle = async () => {
      if (path.startsWith("/.well-known/oauth-protected-resource")) {
        json(response, 200, {
          resource: `${base}/mcp`,
          authorization_servers: [base],
          bearer_methods_supported: ["header"]
        })
      } else if (path === "/.well-known/oauth-authorization-server") {
        json(response, 200, {
          issuer: base,
          authorization_endpoint: `${base}/authorize`,
          token_endpoint: `${base}/token`,
          registration_endpoint: `${base}/register`,
          response_types_supported: ["code"],
          grant_types_supported: ["authorization_code", "refresh_token"],
          code_challenge_methods_supported: ["S256"],
          token_endpoint_auth_methods_supported: ["none"]
        })
      } else if (path === "/register") {
        const registered = registration(await readBody(request))
        if (!registered.redirect_uris.every(allowsRedirect)) {
          json(response, 400, {
            error: "invalid_client_metadata",
            error_description: "redirect_uri is not allowed by the account configuration"
          })
          return
        }
        const clientId = next("client")
        clients.set(clientId, registered.redirect_uris)
        json(response, 201, { ...registered, client_id: clientId })
      } else if (path === "/token") {
        await tokenEndpoint(request, response)
      } else if (path === "/mcp") {
        await resource(request, response, base)
      } else {
        response.writeHead(404)
        response.end()
      }
    }
    void handle().catch((cause: unknown) => {
      response.writeHead(500)
      response.end(String(cause))
    })
  })
  base = await listen(server)

  return {
    url: `${base}/mcp`,
    until,
    heldRefreshes: (): number => heldRefreshes,
    unauthorizedResponses: (): number => unauthorizedResponses,
    refreshAttempts,
    toolCalls,
    grants: (): ReadonlyArray<Readonly<Grant>> => grants,
    registeredRedirects: (): ReadonlyArray<string> =>
      [...clients.values()].flatMap((redirects) => redirects),
    mintGrant: () => {
      const clientId = next("client")
      clients.set(clientId, [])
      const grant = { id: next("grant"), revoked: false }
      grants.push(grant)
      return { clientId, tokens: issue(grant) }
    },
    approve: (authorizationUrl: string): { readonly code: string; readonly state: string } => {
      const url = new URL(authorizationUrl)
      const clientId = url.searchParams.get("client_id") ?? ""
      const redirectUri = url.searchParams.get("redirect_uri") ?? ""
      if (!(clients.get(clientId) ?? []).includes(redirectUri)) {
        throw new Error(`Unregistered redirect URI ${redirectUri} for ${clientId}`)
      }
      const code = next("code")
      codes.set(code, {
        clientId,
        redirectUri,
        challenge: url.searchParams.get("code_challenge") ?? ""
      })
      return { code, state: url.searchParams.get("state") ?? "" }
    },
    invalidateAccessTokens: (): void => {
      accessTokens.clear()
    },
    revokeAllGrants: (): void => {
      for (const grant of grants) grant.revoked = true
    },
    failNextRefreshes: (count: number): void => {
      unavailableRefreshes = count
    },
    holdRefreshes: (): (() => void) => {
      const gate = Promise.withResolvers<void>()
      heldRefresh = gate.promise
      return () => {
        heldRefresh = undefined
        gate.resolve()
      }
    }
  }
}

export type FakeOAuthMcpServer = Awaited<ReturnType<typeof fakeOAuthMcpServer>>

export const sharedCoordinator = (clock: McpOAuthClock) => {
  const records = new Map<string, CredentialRecord>()
  const commands: Array<{
    readonly machine: string
    readonly action: string
    readonly status: string
  }> = []
  const observers = new Set<() => void>()
  const until = async (predicate: () => boolean): Promise<void> => {
    while (!predicate()) {
      const changed = Promise.withResolvers<void>()
      observers.add(changed.resolve)
      try {
        if (predicate()) return
        await changed.promise
      } finally {
        observers.delete(changed.resolve)
      }
    }
  }
  return {
    records,
    commands,
    until,
    leaseReleased: () =>
      until(() => [...records.values()].every((record) => record.operation === undefined)),
    machine:
      (owner: string): CredentialCoordinator =>
      async (id, command) => {
        const next = coordinateCredential(records.get(id), command, owner, clock.now())
        if (next.record !== undefined) records.set(id, next.record)
        commands.push({ machine: owner, action: command.action, status: next.result.status })
        for (const observer of Array.from(observers)) observer()
        return next.result
      }
  }
}

export const listenOn = (
  handler: (request: IncomingMessage, response: ServerResponse) => void
): Promise<string> => listen(createServer(handler))

export const machineVault = (
  coordinator: ReturnType<typeof sharedCoordinator>,
  owner: string,
  clock: McpOAuthClock,
  dataDir: string
) =>
  mcpCredentialVault(dataDir, coordinator.machine(owner), clock.now, {
    elapsed: clock.now,
    wait: coordinator.leaseReleased
  })

type Services = Awaited<ReturnType<typeof makeServices>>["services"]

export const seedLegacyMcpOAuth = async (
  services: Services,
  id: string,
  oauth: Record<string, unknown>
): Promise<void> => {
  const dataDir = dirname(services.attachments.root)
  const key = readFileSync(join(dataDir, "mcp-secret-key"))
  const iv = randomBytes(12)
  const cipher = createCipheriv("aes-256-gcm", key, iv)
  const sealed = Buffer.concat([cipher.update(JSON.stringify({ oauth }), "utf8"), cipher.final()])
  const stored = await Effect.runPromise(services.db.getMcpServer(id))
  if (stored === undefined) throw new Error(`Missing ${id}`)
  await Effect.runPromise(
    services.db.saveMcpServer({
      id: stored.id,
      name: stored.name,
      transport: stored.transport,
      ...(stored.url === undefined ? {} : { url: stored.url }),
      enabled: stored.enabled,
      authType: stored.authType,
      connectionState: stored.connectionState,
      toolCount: stored.toolCount,
      secretCipher: Buffer.concat([iv, cipher.getAuthTag(), sealed]).toString("base64")
    })
  )
}

export const tempDirectory = async (): Promise<string> => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-mcp-vault-"))
  tempDirs.push(directory)
  return directory
}
