import { fixtureChanged, observeDatabase } from "./changes-test-support.js"
import { field } from "./unknown-values.js"
export { waitFor, observableFixture } from "./changes-test-support.js"
import { mkdtempSync, rmSync } from "node:fs"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { EventKind, type EventEnvelope } from "@codevisor/api"
import { canonicalUuid, makeAttachmentStore, makeDatabase } from "@codevisor/db"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { makeMcpManager, type McpManagerConfig } from "@codevisor/mcp"
import type {
  TerminalHandlers,
  TerminalProcess,
  TerminalSpawnRequest,
  TerminalSpawner
} from "@codevisor/terminal"
import { makeTerminalManager } from "@codevisor/terminal"
import Database from "better-sqlite3"
import { Effect, Schema } from "effect"
import { afterEach, beforeEach, onTestFinished, vi } from "vitest"
import { WebSocket } from "ws"

import type { RestartCoordinator } from "./restart-drain.js"
import {
  defaultServerConfig,
  EventFanout,
  makeCodevisorServerApp,
  makeEventFanout,
  startCodevisorServer
} from "./server.js"
import type { RunningCodevisorServer } from "./server.js"
import type { CodevisorServerConfig, CodevisorServerServices, RouteState } from "./server.js"
import { run, makeAgents } from "./test-support-agents.js"
export * from "./test-support-agents.js"
export * from "./test-support-stubs.js"

export const idleRestartCoordinator = (): RestartCoordinator => {
  const startedAt = "2026-06-30T00:00:00.000Z"
  return {
    state: () => ({ state: "idle", remaining: 0, startedAt }),
    isGated: () => false,
    begin: async () => ({ state: "drained", remaining: 0, startedAt }),
    cancel: async () => ({ state: "idle", remaining: 0, startedAt }),
    close: () => {}
  }
}

export const idleRouteState = (): RouteState => ({
  activePromptSessions: new Set(),
  promptTurnReleases: new Map(),
  activeTurnSessions: new Set(),
  gatedSessions: new Map(),
  pendingPromptActions: new Set(),
  pendingSessionCreates: new Map(),
  turnHeldSessions: new Set(),
  updateSignature: {},
  restartHeldSessions: new Set(),
  restart: idleRestartCoordinator(),
  updateResume: {
    resume: () => {},
    isPending: () => false,
    cancel: () => {},
    close: () => {}
  }
})

class FakeProcess implements TerminalProcess {
  readonly writes: Array<string> = []
  readonly resizes: Array<readonly [number, number]> = []
  killCount = 0

  write(data: string): void {
    this.writes.push(data)
  }

  resize(cols: number, rows: number): void {
    this.resizes.push([cols, rows])
  }

  kill(): void {
    this.killCount += 1
  }
}

const makeSpawner = (): TerminalSpawner & {
  readonly requests: ReadonlyArray<TerminalSpawnRequest>
  readonly handlers: ReadonlyArray<TerminalHandlers>
  readonly processes: ReadonlyArray<FakeProcess>
} => {
  const requests: Array<TerminalSpawnRequest> = []
  const handlers: Array<TerminalHandlers> = []
  const processes: Array<FakeProcess> = []
  return {
    requests,
    handlers,
    processes,
    spawn: (request, handler) =>
      Effect.sync(() => {
        const process = new FakeProcess()
        requests.push(request)
        handlers.push(handler)
        processes.push(process)
        return process
      })
  }
}

export const tempDirs: Array<string> = []
export const runningServers: Array<RunningCodevisorServer> = []
export const databases: Array<CodevisorDatabaseService> = []
const mcpManagers: Array<ReturnType<typeof makeMcpManager>> = []
const realFetch = globalThis.fetch

beforeEach(() => {
  vi.stubGlobal("fetch", (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : input)
    if (!["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)) {
      return Promise.reject(new TypeError("External upstream unavailable in this fixture"))
    }
    const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : {}))
    headers.set("Connection", "close")
    return realFetch(input, { ...init, headers })
  })
})

afterEach(async () => {
  const closed = await Promise.allSettled(
    runningServers.splice(0).map((server) => run(server.close))
  )
  const failures = closed.flatMap((result) => (result.status === "rejected" ? [result.reason] : []))
  for (const mcp of mcpManagers.splice(0)) {
    try {
      await mcp.close()
    } catch (cause) {
      failures.push(cause)
    }
  }
  for (const database of databases.splice(0)) {
    try {
      await run(database.close)
    } catch (cause) {
      failures.push(cause)
    }
  }
  for (const dir of tempDirs.splice(0)) {
    try {
      rmSync(dir, { force: true, recursive: true })
    } catch (cause) {
      failures.push(cause)
    }
  }
  try {
    vi.unstubAllGlobals()
  } catch (cause) {
    failures.push(cause)
  }
  if (failures.length > 0) throw new AggregateError(failures, "Cleaning up test resources failed")
})

export const makeServices = async (
  serverId = "test",
  mcpConfig: Partial<
    Pick<McpManagerConfig, "executionTimers" | "packagedSkills" | "skillSource">
  > = {}
) => {
  const dir = mkdtempSync(join(tmpdir(), "codevisor-server-"))
  tempDirs.push(dir)
  const db = await run(makeDatabase({ filename: join(dir, "codevisor.sqlite"), serverId }))
  databases.push(db)
  observeDatabase(db)
  const spawner = makeSpawner()
  const agents = makeAgents()
  const mcp = makeMcpManager({ db, dataDir: dir, serverId, ...mcpConfig })
  mcpManagers.push(mcp)
  onTestFinished(mcp.subscribeServersChanged(fixtureChanged))
  onTestFinished(mcp.subscribeCredentialsRotated(fixtureChanged))
  return {
    agents,
    services: {
      agents,
      attachments: makeAttachmentStore(dir),
      db,
      mcp,
      terminal: makeTerminalManager({ defaultShell: "/bin/sh", env: {}, spawner })
    },
    spawner
  }
}

const readDatabase = <A>(
  services: CodevisorServerServices,
  read: (sqlite: Database.Database) => A
): A => {
  const sqlite = new Database(join(dirname(services.attachments.root), "codevisor.sqlite"), {
    readonly: true
  })
  try {
    return read(sqlite)
  } finally {
    sqlite.close()
  }
}

const EventRow = Schema.Struct({
  id: Schema.Number,
  server_id: Schema.String,
  kind: EventKind,
  subject_id: Schema.String,
  created_at: Schema.String,
  payload: Schema.String
})

const SessionEventRow = Schema.Struct({
  session_id: Schema.String,
  revision: Schema.Number,
  global_event_id: Schema.NullOr(Schema.Number),
  server_id: Schema.String,
  kind: EventKind,
  created_at: Schema.String,
  payload: Schema.String,
  chat_item_id: Schema.NullOr(Schema.String)
})

const globalEvent = (raw: unknown): EventEnvelope => {
  const row = Schema.decodeUnknownSync(EventRow)(raw)
  return {
    id: row.id,
    globalEventId: row.id,
    serverId: row.server_id,
    kind: row.kind,
    subjectId: row.subject_id,
    createdAt: row.created_at,
    payload: JSON.parse(row.payload) as unknown
  }
}

const sessionEvent = (raw: unknown): EventEnvelope => {
  const row = Schema.decodeUnknownSync(SessionEventRow)(raw)
  const payload = JSON.parse(row.payload) as unknown
  return {
    id: row.revision,
    ...(row.global_event_id === null ? {} : { globalEventId: row.global_event_id }),
    subjectRevision: row.revision,
    serverId: row.server_id,
    kind: row.kind,
    subjectId: row.session_id,
    createdAt: row.created_at,
    payload:
      row.chat_item_id !== null &&
      typeof payload === "object" &&
      payload !== null &&
      !Array.isArray(payload)
        ? { ...payload, chatItemId: row.chat_item_id }
        : payload
  }
}

export const listEvents = (
  services: CodevisorServerServices,
  since = 0
): ReadonlyArray<EventEnvelope> =>
  readDatabase(services, (sqlite) =>
    sqlite.prepare("select * from events where id > ? order by id asc").all(since).map(globalEvent)
  )

export const listSubjectEvents = (
  services: CodevisorServerServices,
  rawSubjectId: string,
  since = 0
): ReadonlyArray<EventEnvelope> =>
  readDatabase(services, (sqlite) => {
    const subjectId = canonicalUuid(rawSubjectId)
    const isSession =
      sqlite.prepare("select 1 from sessions where id = ?").get(subjectId) !== undefined
    return isSession
      ? sqlite
          .prepare(
            "select * from session_events where session_id = ? and revision > ? order by revision asc"
          )
          .all(subjectId, since)
          .map(sessionEvent)
      : sqlite
          .prepare("select * from events where subject_id = ? and id > ? order by id asc")
          .all(subjectId, since)
          .map(globalEvent)
  })

export const archiveSessionViaWorkspace = async (
  services: CodevisorServerServices,
  projectId: string,
  sessionId: string
): Promise<void> => {
  const workspace = await run(
    services.db.upsertWorkspace({ projectId, name: "archived", hasCustomName: false })
  )
  await run(services.db.setSessionWorkspace(sessionId, workspace.id))
  await run(services.db.updateWorkspace(workspace.id, { isArchived: true }))
}

export const start = async (
  auth = { allowLocalhostWithoutAuth: true, requireBearerToken: false },
  mcpConfig: Parameters<typeof makeServices>[1] = {}
) => {
  const { agents, services, spawner } = await makeServices("server-a", mcpConfig)
  const server = await run(
    startCodevisorServer(
      services,
      defaultServerConfig({ bootId: "test-boot", auth, id: "server-a", port: 0 })
    )
  )
  runningServers.push(server)
  return { agents, server, services, spawner }
}

export const startWithApp = async (
  services: CodevisorServerServices,
  fanout?: EventFanout,
  configOverrides: Partial<CodevisorServerConfig> = {}
): Promise<RunningCodevisorServer> => {
  const appFanout = fanout ?? (await run(makeEventFanout))
  return await new Promise((resolve, reject) => {
    const app = makeCodevisorServerApp(
      services,
      defaultServerConfig({ bootId: "test-boot", id: "server-a", port: 0, ...configOverrides }),
      appFanout
    )
    const httpServer = createServer(app.handleRequest)
    httpServer.on("upgrade", app.handleUpgrade)
    const failListen = (error: Error): void => {
      void run(app.close).finally(() => reject(error))
    }
    httpServer.once("error", failListen)
    httpServer.listen(0, "127.0.0.1", () => {
      httpServer.off("error", failListen)
      const address = httpServer.address()
      const port = typeof address === "object" && address !== null ? address.port : 0
      let closing: Promise<void> | undefined
      const server: RunningCodevisorServer = {
        close: Effect.promise(() => {
          closing ??= (async () => {
            try {
              await run(app.close)
            } finally {
              await new Promise<void>((closeResolve) => httpServer.close(() => closeResolve()))
            }
          })()
          return closing
        }),
        host: "127.0.0.1",
        port,
        url: `http://127.0.0.1:${port}`
      }
      runningServers.push(server)
      resolve(server)
    })
  })
}

export const jsonRequest = async (
  server: RunningCodevisorServer,
  path: string,
  init: RequestInit = {}
): Promise<{ readonly status: number; readonly body: unknown }> => {
  const headers = new Headers(init.headers)
  if (!headers.has("Content-Type")) headers.set("Content-Type", "application/json")
  const response = await fetch(`${server.url}${path}`, { ...init, headers })
  const text = await response.text()
  return {
    status: response.status,
    body: text.length > 0 ? (JSON.parse(text) as unknown) : undefined
  }
}

const Identified = Schema.Struct({ id: Schema.String })

export const bodyId = (response: { readonly body: unknown }): string =>
  Schema.decodeUnknownSync(Identified)(response.body).id

export const readSseEventsOfKind = async (
  server: RunningCodevisorServer,
  kind: string,
  count: number
): Promise<ReadonlyArray<unknown>> => {
  const controller = new AbortController()
  try {
    const response = await fetch(`${server.url}/v1/events`, { signal: controller.signal })
    const reader = response.body?.getReader()
    if (reader === undefined) {
      throw new Error("Missing response body")
    }
    let buffer = ""
    const events: Array<unknown> = []
    while (events.length < count) {
      const next = await reader.read()
      if (next.done) break
      buffer += new TextDecoder().decode(next.value)
      let index = buffer.indexOf("\n\n")
      while (index !== -1) {
        const chunk = buffer.slice(0, index)
        buffer = buffer.slice(index + 2)
        const data = chunk
          .split("\n")
          .filter((line) => line.startsWith("data: "))
          .map((line) => line.slice("data: ".length))
          .join("\n")
        if (data.length > 0) {
          const parsed: unknown = JSON.parse(data)
          if (field(parsed, "kind") === kind) events.push(parsed)
        }
        index = buffer.indexOf("\n\n")
      }
    }
    return events
  } finally {
    controller.abort()
  }
}

const quietKinds: ReadonlySet<unknown> = new Set(["keepalive", "navigation.changed"])

export const readSseEvents = async (
  server: RunningCodevisorServer,
  expectedCount: number,
  since?: number | string
): Promise<ReadonlyArray<unknown>> => {
  const controller = new AbortController()
  try {
    const eventsUrl =
      since === undefined ? `${server.url}/v1/events` : `${server.url}/v1/events?since=${since}`
    const response = await fetch(eventsUrl, { signal: controller.signal })
    const reader = response.body?.getReader()
    if (reader === undefined) {
      throw new Error("Missing response body")
    }
    let buffer = ""
    const events: Array<unknown> = []
    while (events.length < expectedCount) {
      const next = await reader.read()
      if (next.done) {
        break
      }
      buffer += new TextDecoder().decode(next.value)
      const chunks = buffer.split("\n\n")
      buffer = chunks.pop() ?? ""
      for (const chunk of chunks) {
        const dataLine = chunk.split("\n").find((line) => line.startsWith("data: "))
        if (dataLine !== undefined) {
          const event: unknown = JSON.parse(dataLine.slice("data: ".length))
          if (!quietKinds.has(field(event, "kind"))) events.push(event)
        }
      }
    }
    return events
  } finally {
    controller.abort()
  }
}

export const readWebSocketEvents = async (
  server: RunningCodevisorServer,
  expectedCount: number,
  since?: number | string,
  path = "/v1/events/socket",
  includeControls = false
): Promise<ReadonlyArray<unknown>> => {
  const eventsUrl =
    since === undefined
      ? `${server.url.replace("http:", "ws:")}${path}`
      : `${server.url.replace("http:", "ws:")}${path}?since=${since}`
  const webSocket = new WebSocket(eventsUrl)
  onTestFinished(() => webSocket.terminate())
  const events: Array<unknown> = []
  let isDone = false
  const received = new Promise<ReadonlyArray<unknown>>((resolve, reject) => {
    webSocket.on("message", (data: Buffer) => {
      if (isDone) {
        return
      }
      const event: unknown = JSON.parse(data.toString())
      if (!includeControls && quietKinds.has(field(event, "kind"))) return
      events.push(event)
      if (events.length >= expectedCount) {
        isDone = true
        webSocket.close()
        resolve(events.slice(0, expectedCount))
      }
    })
    webSocket.on("error", reject)
  })
  await new Promise<void>((resolve, reject) => {
    webSocket.once("open", resolve)
    webSocket.once("error", reject)
  })
  return await received
}
