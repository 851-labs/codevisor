import { makeAttachmentStore, makeDatabase } from "@codevisor/db"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type {
  TerminalHandlers,
  TerminalProcess,
  TerminalSpawnRequest,
  TerminalSpawner
} from "@codevisor/terminal"
import { makeTerminalManager } from "@codevisor/terminal"
import { Effect } from "effect"
import { createServer } from "node:http"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { WebSocket } from "ws"
import { afterEach } from "vitest"
import {
  defaultServerConfig,
  EventFanout,
  makeCodevisorServerApp,
  makeEventFanout,
  startCodevisorServer
} from "./server.js"
import type { RunningCodevisorServer } from "./server.js"
import type { CodevisorServerConfig, CodevisorServerServices } from "./server.js"
import type { RestartCoordinator } from "./restart-drain.js"
import { makeMcpManager } from "@codevisor/mcp"
import { run, makeAgents } from "./test-support-agents.js"
export * from "./test-support-agents.js"
export * from "./test-support-stubs.js"

/// A restart coordinator that never gates: for tests that assemble a
/// `RouteState` by hand and don't exercise the restart drain.
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

export class FakeProcess implements TerminalProcess {
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

export const makeSpawner = (): TerminalSpawner & {
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

afterEach(async () => {
  for (const server of runningServers.splice(0)) {
    await run(server.close)
  }
  for (const database of databases.splice(0)) {
    await run(database.close)
  }
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { force: true, recursive: true })
  }
})

export const makeServices = async (serverId = "test") => {
  const dir = mkdtempSync(join(tmpdir(), "codevisor-server-"))
  tempDirs.push(dir)
  const db = await run(makeDatabase({ filename: join(dir, "codevisor.sqlite"), serverId }))
  databases.push(db)
  const spawner = makeSpawner()
  const agents = makeAgents()
  const mcp = makeMcpManager({ db, dataDir: dir, serverId })
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

export const start = async (
  auth = { allowLocalhostWithoutAuth: true, requireBearerToken: false }
) => {
  const { agents, services, spawner } = await makeServices("server-a")
  const server = await run(
    startCodevisorServer(
      services,
      defaultServerConfig({
        auth,
        id: "server-a",
        port: 0
      })
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
      defaultServerConfig({ id: "server-a", port: 0, ...configOverrides }),
      appFanout
    )
    const httpServer = createServer(app.handleRequest)
    httpServer.on("upgrade", app.handleUpgrade)
    httpServer.once("error", reject)
    httpServer.listen(0, "127.0.0.1", () => {
      httpServer.off("error", reject)
      const address = httpServer.address()
      const port = typeof address === "object" && address !== null ? address.port : 0
      resolve({
        close: Effect.promise(
          () =>
            new Promise<void>((closeResolve) => {
              void run(app.close)
              httpServer.close(() => closeResolve())
            })
        ),
        host: "127.0.0.1",
        port,
        url: `http://127.0.0.1:${port}`
      })
    })
  })
}

export const jsonRequest = async (
  server: RunningCodevisorServer,
  path: string,
  init: RequestInit = {}
): Promise<{ readonly status: number; readonly body: unknown }> => {
  const response = await fetch(`${server.url}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...init.headers
    }
  })
  const text = await response.text()
  return {
    status: response.status,
    body: text.length > 0 ? (JSON.parse(text) as unknown) : undefined
  }
}

/// Reads the live stream until `count` events of `kind` have arrived,
/// ignoring interleaved traffic (config-plane sync.changed, readiness
/// publishes) that rides the same stream. Assertions about a specific
/// event kind stay stable as new planes add ambient events.
export const readSseEventsOfKind = async (
  server: RunningCodevisorServer,
  kind: string,
  count: number
): Promise<ReadonlyArray<unknown>> => {
  const controller = new AbortController()
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
        const parsed = JSON.parse(data) as { kind?: string }
        if (parsed.kind === kind) events.push(parsed)
      }
      index = buffer.indexOf("\n\n")
    }
  }
  controller.abort()
  return events
}

export const readSseEvents = async (
  server: RunningCodevisorServer,
  expectedCount: number,
  since?: number | string
): Promise<ReadonlyArray<unknown>> => {
  const controller = new AbortController()
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
        events.push(JSON.parse(dataLine.slice("data: ".length)) as unknown)
      }
    }
  }
  controller.abort()
  return events
}

export const readWebSocketEvents = async (
  server: RunningCodevisorServer,
  expectedCount: number,
  since?: number | string,
  path = "/v1/events/socket"
): Promise<ReadonlyArray<unknown>> => {
  const eventsUrl =
    since === undefined
      ? `${server.url.replace("http:", "ws:")}${path}`
      : `${server.url.replace("http:", "ws:")}${path}?since=${since}`
  const webSocket = new WebSocket(eventsUrl)
  const events: Array<unknown> = []
  let isDone = false
  const received = new Promise<ReadonlyArray<unknown>>((resolve, reject) => {
    const timeout = setTimeout(() => {
      isDone = true
      webSocket.close()
      reject(new Error(`Timed out waiting for ${expectedCount} websocket events`))
    }, 1_000)
    webSocket.on("message", (data) => {
      if (isDone) {
        return
      }
      events.push(JSON.parse(data.toString()) as unknown)
      if (events.length >= expectedCount) {
        isDone = true
        clearTimeout(timeout)
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

export const waitFor = async (
  predicate: () => boolean | Promise<boolean>,
  describeState: () => string = () => ""
): Promise<void> => {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (await predicate()) {
      return
    }
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  throw new Error(`Timed out waiting for condition ${describeState()}`)
}
