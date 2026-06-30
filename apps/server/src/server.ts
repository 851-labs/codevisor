import type { AcpRuntimeService, RuntimeEvent } from "@herdman/acp-runtime"
import type {
  EventEnvelope,
  Harness,
  ServerKind,
  TerminalClientFrame,
  Workspace
} from "@herdman/api"
import {
  CreateSessionRequest as CreateSessionRequestSchema,
  CreateWorkspaceRequest as CreateWorkspaceRequestSchema,
  PromptRequest,
  SetConfigRequest,
  SetModeRequest,
  TerminalClientFrame as TerminalClientFrameSchema,
  TerminalCreateRequest,
  UpdateHarnessRequest as UpdateHarnessRequestSchema,
  UpdateSessionRequest as UpdateSessionRequestSchema,
  UpdateWorkspaceRequest as UpdateWorkspaceRequestSchema,
  decode,
  makeOpenApiDocument
} from "@herdman/api"
import type { HerdManDatabaseService } from "@herdman/db"
import type { TerminalManagerService } from "@herdman/terminal"
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { Socket } from "node:net"
import type { AddressInfo } from "node:net"
import { Context, Effect, Layer, PubSub, Schema } from "effect"
import { WebSocket, WebSocketServer } from "ws"

export class ServerError extends Schema.TaggedErrorClass<ServerError>()("ServerError", {
  operation: Schema.String,
  message: Schema.String
}) {}

export interface HerdManServerAuthConfig {
  readonly requireBearerToken: boolean
  readonly allowLocalhostWithoutAuth: boolean
}

export interface HerdManServerConfig {
  readonly id: string
  readonly name: string
  readonly version: string
  readonly kind: ServerKind
  readonly host: string
  readonly port: number
  readonly auth: HerdManServerAuthConfig
}

export interface HerdManServerServices {
  readonly db: HerdManDatabaseService
  readonly acp: AcpRuntimeService
  readonly terminal: TerminalManagerService
}

export interface RunningHerdManServer {
  readonly url: string
  readonly host: string
  readonly port: number
  readonly close: Effect.Effect<void, ServerError>
}

export interface HerdManServerApp {
  readonly handleRequest: (request: IncomingMessage, response: ServerResponse) => void
  readonly handleUpgrade: (request: IncomingMessage, socket: Socket, head: Buffer) => void
  readonly close: Effect.Effect<void, ServerError>
}

export class HerdManServer extends Context.Service<HerdManServer, HerdManServerServices>()(
  "@herdman/server/HerdManServer"
) {
  static readonly layer = (services: HerdManServerServices): Layer.Layer<HerdManServer> =>
    Layer.succeed(HerdManServer, HerdManServer.of(services))
}

export class EventFanout {
  readonly sinks = new Set<(event: EventEnvelope) => void>()

  constructor(readonly pubsub: PubSub.PubSub<EventEnvelope>) {}

  publish(event: EventEnvelope): Effect.Effect<void> {
    const pubsub = this.pubsub
    const sinks = this.sinks
    return Effect.gen(function* () {
      yield* PubSub.publish(pubsub, event)
      yield* Effect.sync(() => {
        for (const sink of sinks) {
          sink(event)
        }
      })
    })
  }

  subscribe(sink: (event: EventEnvelope) => void): () => void {
    this.sinks.add(sink)
    return () => {
      this.sinks.delete(sink)
    }
  }
}

export const makeEventFanout: Effect.Effect<EventFanout> = Effect.map(
  PubSub.unbounded<EventEnvelope>({ replay: 256 }),
  (pubsub) => new EventFanout(pubsub)
)

export const defaultServerConfig = (
  overrides: Partial<HerdManServerConfig> = {}
): HerdManServerConfig => ({
  id: overrides.id ?? "local",
  name: overrides.name ?? "Local HerdMan",
  version: overrides.version ?? "0.1.0",
  kind: overrides.kind ?? "local",
  host: overrides.host ?? "127.0.0.1",
  port: overrides.port ?? 8765,
  auth: overrides.auth ?? {
    allowLocalhostWithoutAuth: true,
    requireBearerToken: false
  }
})

export const makeHerdManServerApp = (
  services: HerdManServerServices,
  config: HerdManServerConfig,
  fanout: EventFanout,
  webSocketServer = new WebSocketServer({ noServer: true })
): HerdManServerApp => {
  const app = {
    handleRequest: (request: IncomingMessage, response: ServerResponse): void => {
      void handleRequest(services, config, fanout, request, response)
    },
    handleUpgrade: (request: IncomingMessage, socket: Socket, head: Buffer): void => {
      void handleUpgrade(services, config, request, socket, head, webSocketServer)
    },
    close: serverAttempt("closeApp", () => {
      webSocketServer.close()
    })
  }
  return app
}

export const startHerdManServer = (
  services: HerdManServerServices,
  config: HerdManServerConfig
): Effect.Effect<RunningHerdManServer, ServerError> =>
  Effect.gen(function* () {
    const fanout = yield* makeEventFanout
    return yield* Effect.tryPromise({
      try: () =>
        new Promise<RunningHerdManServer>((resolve, reject) => {
          const app = makeHerdManServerApp(services, config, fanout)
          const server = createServer(app.handleRequest)
          server.on("upgrade", app.handleUpgrade)
          server.once("error", reject)
          server.listen(config.port, config.host, () => {
            server.off("error", reject)
            const address = server.address()
            /* v8 ignore next -- TCP listen always returns AddressInfo here. */
            const port = isAddressInfo(address) ? address.port : config.port
            resolve({
              host: config.host,
              port,
              url: `http://${config.host}:${port}`,
              close: closeServer(server, app)
            })
          })
        }),
      /* v8 ignore next -- startup errors are surfaced by Node before a server is returned. */
      catch: (cause) =>
        new ServerError({
          operation: "start",
          message: cause instanceof Error ? cause.message : String(cause)
        })
    })
  })

const handleRequest = async (
  services: HerdManServerServices,
  config: HerdManServerConfig,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> => {
  try {
    const url = parseRequestUrl(request)
    if (request.method === "GET" && url.pathname === "/v1/health") {
      writeJson(response, 200, { ok: true, version: config.version, database: "ready" })
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/events") {
      await authorize(services.db, config, request)
      await handleEvents(services.db, fanout, url, response)
      return
    }

    await authorize(services.db, config, request)

    if (request.method === "GET" && url.pathname === "/v1/info") {
      writeJson(response, 200, {
        id: config.id,
        name: config.name,
        kind: config.kind,
        version: config.version,
        platform: process.platform,
        bindHost: config.host
      })
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/openapi.json") {
      writeJson(response, 200, makeOpenApiDocument(config.version))
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/update") {
      writeJson(response, 200, await run(services.db.getUpdateInfo))
      return
    }

    if (request.method === "POST" && url.pathname === "/v1/auth/pairing-token") {
      writeJson(response, 201, {
        token: await run(services.db.issuePairingToken),
        createdAt: new Date().toISOString()
      })
      return
    }

    if (await routeWorkspaces(services, fanout, request, response, url)) {
      return
    }
    if (await routeHarnesses(services, request, response, url)) {
      return
    }
    if (await routeSessions(services, fanout, request, response, url, config)) {
      return
    }
    if (await routeTerminals(services, request, response, url)) {
      return
    }

    throw new HttpFailure(404, "Route not found")
  } catch (cause) {
    writeFailure(response, cause)
  }
}

const routeWorkspaces = async (
  services: HerdManServerServices,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method === "GET" && url.pathname === "/v1/workspaces") {
    writeJson(response, 200, await run(services.db.listWorkspaces))
    return true
  }

  if (request.method === "POST" && url.pathname === "/v1/workspaces") {
    const workspace = await run(
      services.db.createWorkspace(await readSchema(request, CreateWorkspaceRequestSchema))
    )
    await appendAndPublish(services.db, fanout, "workspace.created", workspace.id, workspace)
    writeJson(response, 201, workspace)
    return true
  }

  const workspaceId = matchRoute(url.pathname, "/v1/workspaces/:id")
  if (workspaceId !== undefined && request.method === "PATCH") {
    const workspace = await run(
      services.db.updateWorkspace(
        workspaceId,
        await readSchema(request, UpdateWorkspaceRequestSchema)
      )
    )
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
    writeJson(response, 200, workspace)
    return true
  }

  if (workspaceId !== undefined && request.method === "DELETE") {
    await run(services.db.deleteWorkspace(workspaceId))
    await appendAndPublish(services.db, fanout, "workspace.deleted", workspaceId, {
      id: workspaceId
    })
    writeJson(response, 204, undefined)
    return true
  }

  return false
}

const routeHarnesses = async (
  services: HerdManServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method === "GET" && url.pathname === "/v1/harnesses") {
    writeJson(response, 200, await discoverHarnesses(services))
    return true
  }

  const harnessId = matchRoute(url.pathname, "/v1/harnesses/:id")
  if (harnessId !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateHarnessRequestSchema)
    await run(services.db.setHarnessEnabled(harnessId, payload.enabled))
    const harness = (await discoverHarnesses(services)).find(
      (candidate) => candidate.id === harnessId
    )
    if (harness === undefined) {
      throw new HttpFailure(404, `Harness not found: ${harnessId}`)
    }
    writeJson(response, 200, harness)
    return true
  }

  return false
}

const routeSessions = async (
  services: HerdManServerServices,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
  config: HerdManServerConfig
): Promise<boolean> => {
  if (request.method === "GET" && url.pathname === "/v1/sessions") {
    writeJson(response, 200, await run(services.db.listSessions))
    return true
  }

  if (request.method === "POST" && url.pathname === "/v1/sessions") {
    const payload = await readSchema(request, CreateSessionRequestSchema)
    const workspace = await getWorkspaceOrFail(services.db, payload.workspaceId)
    const agentSessionId =
      payload.agentSessionId ??
      (await run(services.acp.createAgentSession(payload.harnessId, workspace.folderPath)))
    const session = await run(
      services.db.createSession({
        ...payload,
        agentSessionId
      })
    )
    await appendAndPublish(services.db, fanout, "session.created", session.id, session)
    writeJson(response, 201, session)
    return true
  }

  const sessionId = matchRoute(url.pathname, "/v1/sessions/:id")
  if (sessionId !== undefined && request.method === "GET") {
    writeJson(response, 200, await run(services.db.getSessionDetail(sessionId)))
    return true
  }

  if (sessionId !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateSessionRequestSchema)
    const session = await run(services.db.updateSession(sessionId, payload))
    await appendAndPublish(
      services.db,
      fanout,
      session.isArchived ? "session.archived" : "session.updated",
      session.id,
      session
    )
    writeJson(response, 200, session)
    return true
  }

  if (sessionId !== undefined && request.method === "DELETE") {
    await run(services.db.deleteSession(sessionId))
    await appendAndPublish(services.db, fanout, "session.deleted", sessionId, { id: sessionId })
    writeJson(response, 204, undefined)
    return true
  }

  if (await routeSessionActions(services, fanout, request, response, url, config)) {
    return true
  }

  return false
}

const routeSessionActions = async (
  services: HerdManServerServices,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
  config: HerdManServerConfig
): Promise<boolean> => {
  const promptSessionId = matchRoute(url.pathname, "/v1/sessions/:id/prompt")
  if (promptSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, PromptRequest)
    await run(services.db.appendConversationItem(promptSessionId, "user", payload.text, false))
    const result = await run(services.acp.prompt(promptSessionId, payload.text))
    for (const event of result.events) {
      await materializeRuntimeEvent(services.db, fanout, config.id, event)
    }
    writeJson(response, 202, { stopReason: result.stopReason })
    return true
  }

  const cancelSessionId = matchRoute(url.pathname, "/v1/sessions/:id/cancel")
  if (cancelSessionId !== undefined && request.method === "POST") {
    await materializeRuntimeEvent(
      services.db,
      fanout,
      config.id,
      await run(services.acp.cancel(cancelSessionId))
    )
    writeJson(response, 202, { cancelled: true })
    return true
  }

  const modeSessionId = matchRoute(url.pathname, "/v1/sessions/:id/mode")
  if (modeSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, SetModeRequest)
    await materializeRuntimeEvent(
      services.db,
      fanout,
      config.id,
      await run(services.acp.setMode(modeSessionId, payload.modeId))
    )
    writeJson(response, 202, { modeId: payload.modeId })
    return true
  }

  const configSessionId = matchRoute(url.pathname, "/v1/sessions/:id/config")
  if (configSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, SetConfigRequest)
    await materializeRuntimeEvent(
      services.db,
      fanout,
      config.id,
      await run(services.acp.setConfigOption(configSessionId, payload.configId, payload.value))
    )
    writeJson(response, 202, { configId: payload.configId })
    return true
  }

  return false
}

const routeTerminals = async (
  services: HerdManServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method === "POST" && url.pathname === "/v1/terminals") {
    writeJson(
      response,
      201,
      await run(services.terminal.createTerminal(await readSchema(request, TerminalCreateRequest)))
    )
    return true
  }

  return false
}

const handleEvents = async (
  db: HerdManDatabaseService,
  fanout: EventFanout,
  url: URL,
  response: ServerResponse
): Promise<void> => {
  const since = Number(url.searchParams.get("since") ?? "0")
  response.writeHead(200, {
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "Content-Type": "text/event-stream"
  })
  for (const event of await run(db.listEvents(Number.isFinite(since) ? since : 0))) {
    writeSse(response, event)
  }
  const unsubscribe = fanout.subscribe((event) => writeSse(response, event))
  response.on("close", unsubscribe)
}

const handleUpgrade = async (
  services: HerdManServerServices,
  config: HerdManServerConfig,
  request: IncomingMessage,
  socket: Socket,
  head: Buffer,
  webSocketServer: WebSocketServer
): Promise<void> => {
  try {
    await authorize(services.db, config, request)
    const url = parseRequestUrl(request)
    const terminalId = matchRoute(url.pathname, "/v1/terminals/:id/socket")
    if (terminalId === undefined) {
      socket.destroy()
      return
    }

    webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
      void attachTerminalSocket(services.terminal, terminalId, webSocket)
    })
  } catch {
    socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n")
    socket.destroy()
  }
}

const attachTerminalSocket = async (
  terminal: TerminalManagerService,
  terminalId: string,
  webSocket: WebSocket
): Promise<void> => {
  try {
    const disconnect = await run(
      terminal.connectTerminal(terminalId, (frame) => {
        /* v8 ignore next -- the close event removes this sink before normal closed-socket output. */
        if (webSocket.readyState === WebSocket.OPEN) {
          webSocket.send(JSON.stringify(frame))
        }
      })
    )
    webSocket.on("message", (data) => {
      const frame = parseTerminalFrameOrSend(data.toString(), webSocket)
      if (frame === undefined) {
        return
      }
      void run(terminal.handleClientFrame(terminalId, frame)).catch((cause: unknown) => {
        webSocket.send(JSON.stringify({ type: "error", message: failureMessage(cause) }))
      })
    })
    webSocket.on("close", disconnect)
  } catch (cause) {
    webSocket.send(JSON.stringify({ type: "error", message: failureMessage(cause) }))
    webSocket.close()
  }
}

const authorize = async (
  db: HerdManDatabaseService,
  config: HerdManServerConfig,
  request: IncomingMessage
): Promise<void> => {
  if (!config.auth.requireBearerToken) {
    return
  }
  if (config.auth.allowLocalhostWithoutAuth && isLocalhost(request.socket.remoteAddress)) {
    return
  }
  const token = parseBearerToken(request.headers.authorization)
  if (token !== undefined && (await run(db.verifyBearerToken(token)))) {
    return
  }
  throw new HttpFailure(401, "Unauthorized")
}

const discoverHarnesses = async (
  services: HerdManServerServices
): Promise<ReadonlyArray<Harness>> =>
  run(services.db.applyHarnessSettings(await run(services.acp.discoverHarnesses)))

const getWorkspaceOrFail = async (
  db: HerdManDatabaseService,
  workspaceId: string
): Promise<Workspace> => {
  const workspace = (await run(db.listWorkspaces)).find((candidate) => candidate.id === workspaceId)
  if (workspace === undefined) {
    throw new HttpFailure(404, `Workspace not found: ${workspaceId}`)
  }
  return workspace
}

const materializeRuntimeEvent = async (
  db: HerdManDatabaseService,
  fanout: EventFanout,
  serverId: string,
  event: RuntimeEvent
): Promise<void> => {
  if (event.kind === "session.output" && isConversationPayload(event.payload)) {
    await run(
      db.appendConversationItem(event.subjectId, event.payload.role, event.payload.text, false)
    )
  }
  await appendAndPublish(db, fanout, event.kind, event.subjectId, {
    ...objectPayload(event.payload),
    serverId
  })
}

const appendAndPublish = async (
  db: HerdManDatabaseService,
  fanout: EventFanout,
  kind: EventEnvelope["kind"],
  subjectId: string,
  payload: unknown
): Promise<EventEnvelope> => {
  const event = await run(db.appendEvent(kind, subjectId, payload))
  await run(fanout.publish(event))
  return event
}

const readSchema = async <S extends Schema.ConstraintDecoder<unknown>>(
  request: IncomingMessage,
  schema: S
): Promise<S["Type"]> => {
  try {
    return decode(schema)(await readJson(request))
  } catch (cause) {
    throw new HttpFailure(400, failureMessage(cause))
  }
}

const readJson = async (request: IncomingMessage): Promise<unknown> => {
  const chunks: Array<Buffer> = []
  for await (const chunk of request) {
    /* v8 ignore next -- Node HTTP request body chunks are Buffers in this server. */
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
  }
  const raw = Buffer.concat(chunks).toString("utf8")
  if (raw.length === 0) {
    return {}
  }
  try {
    return JSON.parse(raw) as unknown
  } catch {
    throw new HttpFailure(400, "Request body must be valid JSON")
  }
}

const parseTerminalFrame = (raw: string): TerminalClientFrame => {
  try {
    return decode(TerminalClientFrameSchema)(JSON.parse(raw) as unknown)
  } catch (cause) {
    throw new HttpFailure(400, failureMessage(cause))
  }
}

const parseTerminalFrameOrSend = (
  raw: string,
  webSocket: WebSocket
): TerminalClientFrame | undefined => {
  try {
    return parseTerminalFrame(raw)
  } catch (cause) {
    webSocket.send(JSON.stringify({ type: "error", message: failureMessage(cause) }))
    return undefined
  }
}

const writeJson = (response: ServerResponse, status: number, body: unknown): void => {
  if (status === 204) {
    response.writeHead(status)
    response.end()
    return
  }
  response.writeHead(status, { "Content-Type": "application/json" })
  response.end(JSON.stringify(body))
}

const writeFailure = (response: ServerResponse, cause: unknown): void => {
  /* v8 ignore next -- errors after SSE headers are ended defensively. */
  if (response.headersSent) {
    response.end()
    return
  }
  if (cause instanceof HttpFailure) {
    writeJson(response, cause.status, { error: cause.message })
    return
  }
  writeJson(response, 500, { error: failureMessage(cause) })
}

const writeSse = (response: ServerResponse, event: EventEnvelope): void => {
  response.write(`id: ${event.id}\n`)
  response.write(`event: ${event.kind}\n`)
  response.write(`data: ${JSON.stringify(event)}\n\n`)
}

const parseRequestUrl = (request: IncomingMessage): URL => {
  /* v8 ignore next -- Node HTTP requests always provide url and host in these paths. */
  return new URL(request.url ?? "/", `http://${request.headers.host ?? "127.0.0.1"}`)
}

const matchRoute = (pathname: string, pattern: string): string | undefined => {
  const pathParts = pathname.split("/").filter(Boolean)
  const patternParts = pattern.split("/").filter(Boolean)
  if (pathParts.length !== patternParts.length) {
    return undefined
  }
  let captured: string | undefined
  for (let index = 0; index < patternParts.length; index += 1) {
    const patternPart = patternParts[index] as string
    const pathPart = pathParts[index] as string
    if (patternPart.startsWith(":")) {
      captured = decodeURIComponent(pathPart)
    } else if (patternPart !== pathPart) {
      return undefined
    }
  }
  return captured
}

const parseBearerToken = (header: string | undefined): string | undefined => {
  if (header === undefined || !header.startsWith("Bearer ")) {
    return undefined
  }
  return header.slice("Bearer ".length)
}

const localhostAddresses = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"])

const isLocalhost = (address: string | undefined): boolean =>
  localhostAddresses.has(String(address))

const conversationRoles = new Set(["user", "assistant", "system"])

const isConversationPayload = (
  payload: unknown
): payload is { readonly role: "user" | "assistant" | "system"; readonly text: string } =>
  typeof payload === "object" &&
  payload !== null &&
  "role" in payload &&
  "text" in payload &&
  conversationRoles.has(String(payload.role)) &&
  typeof payload.text === "string"

const objectPayload = (payload: unknown): Record<string, unknown> =>
  typeof payload === "object" && payload !== null && !Array.isArray(payload)
    ? (payload as Record<string, unknown>)
    : { value: payload }

/* v8 ignore next -- route/runtime failures use Error-compatible values. */
const failureMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const isAddressInfo = (address: string | AddressInfo | null): address is AddressInfo =>
  typeof address === "object" && address !== null && "port" in address

class HttpFailure extends Error {
  constructor(
    readonly status: number,
    message: string
  ) {
    super(message)
  }
}

const closeServer = (server: Server, app: HerdManServerApp): Effect.Effect<void, ServerError> =>
  Effect.tryPromise({
    try: () =>
      new Promise<void>((resolve, reject) => {
        void Effect.runPromise(app.close)
        /* v8 ignore next -- normal test shutdown closes cleanly. */
        server.close((error) => (error === undefined ? resolve() : reject(error)))
      }),
    /* v8 ignore next -- normal test shutdown closes cleanly. */
    catch: (cause) =>
      new ServerError({
        operation: "close",
        message: failureMessage(cause)
      })
  })

const serverAttempt = <A>(operation: string, runSync: () => A): Effect.Effect<A, ServerError> =>
  Effect.try({
    try: runSync,
    /* v8 ignore next -- app close only wraps defensive WebSocket close failures. */
    catch: (cause) =>
      new ServerError({
        operation,
        message: failureMessage(cause)
      })
  })

export const defaultDatabasePath = (): string => join(tmpdir(), "herdman-server.sqlite")
