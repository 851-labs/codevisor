import type {
  AgentRuntimeService,
  PromptInput,
  RuntimeEvent,
  RuntimeEventSink
} from "@herdman/agent-runtime"
import type { Harness } from "@herdman/api"
import { makeDatabase, type HerdManDatabaseService } from "@herdman/db"
import Database from "better-sqlite3"
import type {
  TerminalHandlers,
  TerminalProcess,
  TerminalSpawnRequest,
  TerminalSpawner
} from "@herdman/terminal"
import { makeTerminalManager } from "@herdman/terminal"
import { Effect } from "effect"
import { execFile } from "node:child_process"
import { createServer } from "node:http"
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  utimesSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"
import { WebSocket } from "ws"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  defaultDatabasePath,
  defaultServerConfig,
  EventFanout,
  HerdManServer,
  makeHerdManServerApp,
  makeEventFanout,
  startHerdManServer,
  sweepAttachmentTempFiles,
  type RunningHerdManServer
} from "./server.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const harnesses: ReadonlyArray<Harness> = [
  {
    id: "codex",
    name: "Codex",
    symbolName: "chevron.left.forwardslash.chevron.right",
    source: "registry",
    launchKind: "npx",
    enabled: true,
    readiness: { state: "ready" }
  }
]

const makeAgents = (): AgentRuntimeService & {
  readonly loads: Array<readonly [string, string, string]>
  readonly prompts: Array<readonly [string, string | PromptInput]>
  readonly cancellations: Array<string>
  readonly modes: Array<readonly [string, string]>
  readonly configs: Array<readonly [string, string, string]>
  readonly inspections: Array<readonly [string, string]>
  readonly creations: Array<readonly [string, string]>
  readonly sinks: Map<string, RuntimeEventSink>
  readonly emit: (sessionId: string, event: RuntimeEvent) => Promise<void>
} => {
  const loads: Array<readonly [string, string, string]> = []
  const prompts: Array<readonly [string, string | PromptInput]> = []
  const cancellations: Array<string> = []
  const modes: Array<readonly [string, string]> = []
  const configs: Array<readonly [string, string, string]> = []
  const inspections: Array<readonly [string, string]> = []
  const creations: Array<readonly [string, string]> = []
  const sinks = new Map<string, RuntimeEventSink>()
  const emit = async (sessionId: string, event: RuntimeEvent): Promise<void> => {
    await sinks.get(sessionId)?.(event)
  }
  return {
    loads,
    prompts,
    cancellations,
    modes,
    configs,
    inspections,
    creations,
    sinks,
    emit,
    discoverHarnesses: Effect.succeed(harnesses),
    createAgentSession: (harnessId, cwd, sink) =>
      Effect.promise(
        () =>
          new Promise<string>((resolve) => {
            creations.push([harnessId, cwd])
            setTimeout(() => {
              const sessionId = `agent-${harnessId}-${cwd.split("/").at(-1) ?? "root"}`
              sinks.set(sessionId, sink)
              resolve(sessionId)
            }, 5)
          })
      ),
    inspectHarness: (harnessId, cwd) =>
      Effect.sync(() => {
        inspections.push([harnessId, cwd])
        if (cwd.includes("capability-fail")) {
          throw new Error("capability probe failed")
        }
        if (cwd.includes("no-modes")) {
          return {
            sessionId: `inspect-${harnessId}`,
            configOptions: []
          }
        }
        return {
          sessionId: `inspect-${harnessId}`,
          modes: {
            currentModeId: "default",
            availableModes: [{ id: "default", name: "Default" }]
          },
          configOptions: [
            {
              id: "model",
              name: "Model",
              category: "model",
              currentValue: "gpt-5",
              options: [{ value: "gpt-5", name: "GPT-5" }]
            },
            {
              id: "reasoning",
              name: "Reasoning",
              category: "thought_level",
              currentValue: "medium",
              options: [{ value: "medium", name: "Medium" }]
            }
          ]
        }
      }),
    loadAgentSession: (harnessId, agentSessionId, cwd, sink) =>
      Effect.sync(() => {
        loads.push([harnessId, agentSessionId, cwd])
        sinks.set(agentSessionId, sink)
        return agentSessionId
      }),
    prompt: (sessionId, input) =>
      Effect.promise(async () => {
        prompts.push([sessionId, input])
        const text = typeof input === "string" ? input : input.text
        if (text === "slow prompt") {
          await new Promise((resolve) => setTimeout(resolve, 250))
        }
        if (text === "prompt fails") {
          throw new Error("prompt failed")
        }
        const turnId = `turn-${prompts.length}`
        await emit(sessionId, {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { initiatedBy: "user", turnId, turnState: "started" }
        })
        const events =
          text === "raw chunks" || text === "returned events"
            ? [
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { text, type: "text" },
                    messageId: "user-raw",
                    sessionUpdate: "user_message_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { text: "raw user without id", type: "text" },
                    sessionUpdate: "user_message_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { text: "Raw answer", type: "text" },
                    messageId: "assistant-raw",
                    sessionUpdate: "agent_message_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { text: "Raw answer without id", type: "text" },
                    sessionUpdate: "agent_message_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { text: "thought", type: "text" },
                    messageId: "thought-raw",
                    sessionUpdate: "agent_thought_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { type: "image" },
                    messageId: "image-raw",
                    sessionUpdate: "agent_message_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    role: "assistant",
                    text: 42
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    role: "assistant",
                    text: "bad message id",
                    messageId: 42
                  }
                }
              ]
            : [
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: { role: "assistant", text: `Echo: ${text}` }
                }
              ]
        for (const event of events) {
          await emit(sessionId, event)
        }
        await emit(sessionId, {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { initiatedBy: "user", stopReason: "end_turn", turnId, turnState: "ended" }
        })
        return { stopReason: "end_turn" }
      }),
    cancel: (sessionId) =>
      Effect.sync(() => {
        cancellations.push(sessionId)
      }),
    setMode: (sessionId, modeId) =>
      Effect.promise(async () => {
        modes.push([sessionId, modeId])
        await emit(sessionId, {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { modeId }
        })
      }),
    setConfigOption: (sessionId, configId, value) =>
      Effect.promise(async () => {
        configs.push([sessionId, configId, value])
        await emit(sessionId, {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { configId, configOptions: [], value }
        })
      })
  }
}

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

const tempDirs: Array<string> = []
const runningServers: Array<RunningHerdManServer> = []
const databases: Array<HerdManDatabaseService> = []

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

const makeServices = async (serverId = "test") => {
  const dir = mkdtempSync(join(tmpdir(), "herdman-server-"))
  tempDirs.push(dir)
  const db = await run(makeDatabase({ filename: join(dir, "herdman.sqlite"), serverId }))
  databases.push(db)
  const spawner = makeSpawner()
  const agents = makeAgents()
  return {
    agents,
    services: {
      agents,
      db,
      terminal: makeTerminalManager({ defaultShell: "/bin/sh", env: {}, spawner })
    },
    spawner
  }
}

const start = async (auth = { allowLocalhostWithoutAuth: true, requireBearerToken: false }) => {
  const { agents, services, spawner } = await makeServices("server-a")
  const server = await run(
    startHerdManServer(
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

const startWithApp = async (
  services: Awaited<ReturnType<typeof makeServices>>["services"],
  fanout?: EventFanout
): Promise<RunningHerdManServer> => {
  const appFanout = fanout ?? (await run(makeEventFanout))
  return await new Promise((resolve, reject) => {
    const app = makeHerdManServerApp(
      services,
      defaultServerConfig({ id: "server-a", port: 0 }),
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

const jsonRequest = async (
  server: RunningHerdManServer,
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

const readSseEvents = async (
  server: RunningHerdManServer,
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

const readWebSocketEvents = async (
  server: RunningHerdManServer,
  expectedCount: number,
  since?: number | string
): Promise<ReadonlyArray<unknown>> => {
  const eventsUrl =
    since === undefined
      ? `${server.url.replace("http:", "ws:")}/v1/events/socket`
      : `${server.url.replace("http:", "ws:")}/v1/events/socket?since=${since}`
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

const waitFor = async (
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

describe("@herdman/server", () => {
  it("serves health, info, OpenAPI, update state, pairing, and auth", async () => {
    const { server, services } = await start()

    expect((await jsonRequest(server, "/v1/health")).body).toMatchObject({
      database: "ready",
      ok: true
    })
    expect((await jsonRequest(server, "/v1/info")).body).toMatchObject({
      id: "server-a",
      kind: "local"
    })
    expect((await jsonRequest(server, "/v1/openapi.json")).body).toMatchObject({
      openapi: "3.1.0"
    })
    expect((await jsonRequest(server, "/v1/update")).body).toMatchObject({
      migrationState: "idle"
    })
    expect(defaultServerConfig()).toMatchObject({
      host: "127.0.0.1",
      id: "local",
      kind: "local",
      name: "Local HerdMan",
      port: 49361,
      version: "0.1.0"
    })
    expect(
      (await jsonRequest(server, "/v1/auth/pairing-token", { method: "POST" })).body
    ).toMatchObject({
      token: expect.stringMatching(/^hm_/)
    })
    expect(defaultDatabasePath()).toContain("herdman-server.sqlite")

    // Shutdown is acknowledged even when the host process installed no handler.
    expect((await jsonRequest(server, "/v1/shutdown", { method: "POST" })).status).toBe(202)

    // Servers without an updater refuse remote update requests.
    expect((await jsonRequest(server, "/v1/update/apply", { method: "POST" })).status).toBe(409)

    let shutdownRequests = 0
    const stoppable = await run(
      startHerdManServer(
        services,
        defaultServerConfig({
          id: "server-stoppable",
          onShutdownRequested: () => {
            shutdownRequests += 1
          },
          port: 0
        })
      )
    )
    runningServers.push(stoppable)
    const shutdownResponse = await jsonRequest(stoppable, "/v1/shutdown", { method: "POST" })
    expect(shutdownResponse.status).toBe(202)
    expect(shutdownResponse.body).toMatchObject({ ok: true })
    expect(shutdownRequests).toBe(1)

    // Servers with an updater report fresh update state and apply on request.
    const updaterState = { available: true, applyCalls: 0, applyFails: false }
    const updatable = await run(
      startHerdManServer(
        services,
        defaultServerConfig({
          id: "server-updatable",
          port: 0,
          updater: {
            apply: async () => {
              updaterState.applyCalls += 1
              if (updaterState.applyFails) {
                throw new Error("apply failed")
              }
            },
            check: async () => ({
              channel: "stable",
              checkedAt: "2026-06-30T00:00:00.000Z",
              currentVersion: "0.1.0",
              latestVersion: updaterState.available ? "0.2.0" : "0.1.0",
              migrationState: "idle" as const,
              updateAvailable: updaterState.available
            })
          }
        })
      )
    )
    runningServers.push(updatable)

    expect((await jsonRequest(updatable, "/v1/update")).body).toMatchObject({
      latestVersion: "0.2.0",
      updateAvailable: true
    })
    const applied = await jsonRequest(updatable, "/v1/update/apply", { method: "POST" })
    expect(applied.status).toBe(202)
    expect(applied.body).toMatchObject({ accepted: true, targetVersion: "0.2.0" })
    await waitFor(() => updaterState.applyCalls === 1)

    // A failing apply is swallowed after the 202 acknowledgement.
    updaterState.applyFails = true
    expect((await jsonRequest(updatable, "/v1/update/apply", { method: "POST" })).status).toBe(202)
    await waitFor(() => updaterState.applyCalls === 2)

    // Nothing to apply when already up to date.
    updaterState.available = false
    const upToDate = await jsonRequest(updatable, "/v1/update/apply", { method: "POST" })
    expect(upToDate.status).toBe(200)
    expect(upToDate.body).toMatchObject({ accepted: false, targetVersion: "0.1.0" })
    expect(updaterState.applyCalls).toBe(2)

    const token = await run(services.db.issuePairingToken)
    const secured = await run(
      startHerdManServer(
        services,
        defaultServerConfig({
          auth: {
            allowLocalhostWithoutAuth: false,
            requireBearerToken: true
          },
          id: "server-secure",
          port: 0
        })
      )
    )
    runningServers.push(secured)
    expect((await jsonRequest(secured, "/v1/info")).status).toBe(401)
    expect(
      (
        await jsonRequest(secured, "/v1/info", {
          headers: { Authorization: "Token nope" }
        })
      ).status
    ).toBe(401)
    expect(
      (
        await jsonRequest(secured, "/v1/info", {
          headers: { Authorization: "Bearer hm_wrong" }
        })
      ).status
    ).toBe(401)
    expect(
      (
        await jsonRequest(secured, "/v1/info", {
          headers: { Authorization: `Bearer ${token}` }
        })
      ).status
    ).toBe(200)
    const unauthorizedSocket = new WebSocket(
      `${secured.url.replace("http:", "ws:")}/v1/terminals/missing/socket`
    )
    await new Promise<void>((resolve) => {
      unauthorizedSocket.once("close", resolve)
      unauthorizedSocket.once("error", () => resolve())
    })

    const localhostSecured = await run(
      startHerdManServer(
        services,
        defaultServerConfig({
          auth: {
            allowLocalhostWithoutAuth: true,
            requireBearerToken: true
          },
          id: "server-local-secure",
          port: 0
        })
      )
    )
    runningServers.push(localhostSecured)
    expect((await jsonRequest(localhostSecured, "/v1/info")).status).toBe(200)
  })

  it("applies the CORS allowlist to browser origins", async () => {
    const { services } = await makeServices("server-cors")
    const server = await run(
      startHerdManServer(
        services,
        defaultServerConfig({
          corsOrigins: ["tauri://localhost"],
          id: "server-cors",
          port: 0
        })
      )
    )
    runningServers.push(server)

    // Allowlisted origins are echoed on responses and granted on preflight.
    const allowed = await fetch(`${server.url}/v1/health`, {
      headers: { Origin: "tauri://localhost" }
    })
    expect(allowed.headers.get("access-control-allow-origin")).toBe("tauri://localhost")
    expect(allowed.headers.get("vary")).toBe("Origin")

    const preflight = await fetch(`${server.url}/v1/workspaces`, {
      headers: { "Access-Control-Request-Method": "POST", Origin: "tauri://localhost" },
      method: "OPTIONS"
    })
    expect(preflight.status).toBe(204)
    expect(preflight.headers.get("access-control-allow-origin")).toBe("tauri://localhost")
    expect(preflight.headers.get("access-control-allow-methods")).toContain("POST")
    expect(preflight.headers.get("access-control-allow-headers")).toContain("Authorization")

    // Unknown origins get no grant; their preflight carries no allow-origin.
    const denied = await fetch(`${server.url}/v1/health`, {
      headers: { Origin: "https://evil.example" }
    })
    expect(denied.headers.get("access-control-allow-origin")).toBeNull()
    const deniedPreflight = await fetch(`${server.url}/v1/health`, {
      headers: { Origin: "https://evil.example" },
      method: "OPTIONS"
    })
    expect(deniedPreflight.headers.get("access-control-allow-origin")).toBeNull()

    // Without a configured allowlist, no CORS headers are emitted at all.
    const { services: plainServices } = await makeServices("server-no-cors")
    const plain = await run(
      startHerdManServer(plainServices, defaultServerConfig({ id: "server-no-cors", port: 0 }))
    )
    runningServers.push(plain)
    const noCors = await fetch(`${plain.url}/v1/health`, {
      headers: { Origin: "tauri://localhost" }
    })
    expect(noCors.headers.get("access-control-allow-origin")).toBeNull()
  })

  it("manages workspaces, harnesses, sessions, actions, and event replay", async () => {
    const { agents, server, services } = await start()
    const workspaceRoot = mkdtempSync(join(tmpdir(), "herdman-server-workspace-"))
    tempDirs.push(workspaceRoot)
    const workspaceFolder = join(workspaceRoot, "herdman")
    const noModesFolder = join(workspaceRoot, "no-modes")
    const capabilityFailFolder = join(workspaceRoot, "capability-fail")
    const cwdFile = join(workspaceRoot, "cwd-file")
    mkdirSync(workspaceFolder)
    mkdirSync(noModesFolder)
    mkdirSync(capabilityFailFolder)
    writeFileSync(cwdFile, "")
    const legacyRoot = mkdtempSync(join(tmpdir(), "herdman-server-legacy-"))
    tempDirs.push(legacyRoot)
    const legacyWorkspaceFolder = join(legacyRoot, "legacy-agent-session")
    mkdirSync(legacyWorkspaceFolder)
    const badJson = await fetch(`${server.url}/v1/projects`, {
      body: "{",
      headers: { "Content-Type": "application/json" },
      method: "POST"
    })
    expect(badJson.status).toBe(400)
    expect((await jsonRequest(server, "/v1/missing")).status).toBe(404)
    expect((await jsonRequest(server, "/v1/not-sessions/session-a/queue/item-a")).status).toBe(404)

    const workspaceResponse = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: workspaceFolder, id: "workspace-client-id" }),
      method: "POST"
    })
    expect(workspaceResponse.status).toBe(201)
    const workspace = workspaceResponse.body as { readonly id: string }
    expect(workspace.id).toBe("workspace-client-id")
    expect((await jsonRequest(server, "/v1/projects")).body).toMatchObject([{ id: workspace.id }])
    expect(
      (
        await jsonRequest(server, `/v1/projects/${workspace.id}`, {
          body: JSON.stringify({ name: "Renamed" }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ name: "Renamed" })

    expect((await jsonRequest(server, "/v1/harnesses")).body).toMatchObject([
      { id: "codex", enabled: true }
    ])
    const capabilitiesResponse = await jsonRequest(
      server,
      `/v1/capabilities?cwd=${encodeURIComponent(workspaceFolder)}`
    )
    expect(capabilitiesResponse.body).toMatchObject({
      harnesses: [
        {
          harness: { id: "codex" },
          modes: { currentModeId: "default" },
          configOptions: [
            { category: "model", currentValue: "gpt-5", id: "model" },
            { category: "thought_level", currentValue: "medium", id: "reasoning" }
          ]
        }
      ]
    })
    expect(agents.inspections).toEqual([["codex", workspaceFolder]])
    expect((await jsonRequest(server, "/v1/capabilities")).body).toMatchObject({
      harnesses: [{ harness: { id: "codex" } }]
    })
    const missingCwdCapabilities = await jsonRequest(
      server,
      "/v1/capabilities?cwd=%2Ftmp%2Fmissing-herdman-workspace"
    )
    expect(missingCwdCapabilities.body).toMatchObject({
      harnesses: [{ harness: { id: "codex" } }]
    })
    expect(
      (
        missingCwdCapabilities.body as {
          readonly harnesses: ReadonlyArray<{
            readonly configOptions: ReadonlyArray<{ readonly id: string }>
          }>
        }
      ).harnesses[0]?.configOptions.map((option) => option.id)
    ).toContain("model")
    expect(agents.inspections.at(-1)).toEqual(["codex", tmpdir()])
    expect(
      (await jsonRequest(server, `/v1/capabilities?cwd=${encodeURIComponent(cwdFile)}`)).body
    ).toMatchObject({
      harnesses: [{ harness: { id: "codex" } }]
    })
    expect(agents.inspections.at(-1)).toEqual(["codex", tmpdir()])
    expect(
      (await jsonRequest(server, `/v1/capabilities?cwd=${encodeURIComponent(noModesFolder)}`)).body
    ).toMatchObject({
      harnesses: [{ configOptions: [], harness: { id: "codex" } }]
    })
    expect(
      (
        await jsonRequest(
          server,
          `/v1/capabilities?cwd=${encodeURIComponent(capabilityFailFolder)}`
        )
      ).body
    ).toMatchObject({
      harnesses: [{ configOptions: [], harness: { id: "codex" } }]
    })
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex", {
          body: JSON.stringify({ enabled: false }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ id: "codex", enabled: false })
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/missing", {
          body: JSON.stringify({ enabled: true }),
          method: "PATCH"
        })
      ).status
    ).toBe(404)

    const sessionResponse = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({ projectId: workspace.id, harnessId: "codex", title: "First chat" }),
      method: "POST"
    })
    const session = sessionResponse.body as { readonly id: string; readonly agentSessionId: string }
    expect(session.agentSessionId).toBe("agent-codex-herdman")
    expect(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            id: session.id,
            projectId: workspace.id,
            harnessId: "codex",
            title: "First chat"
          }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ agentSessionId: "agent-codex-herdman", id: session.id })

    const concurrentSessionBody = JSON.stringify({
      id: "client-session-concurrent",
      projectId: workspace.id,
      harnessId: "codex",
      title: "Concurrent chat"
    })
    const [firstConcurrent, secondConcurrent] = await Promise.all([
      jsonRequest(server, "/v1/sessions", {
        body: concurrentSessionBody,
        method: "POST"
      }),
      jsonRequest(server, "/v1/sessions", {
        body: concurrentSessionBody,
        method: "POST"
      })
    ])
    expect([firstConcurrent.status, secondConcurrent.status].sort()).toEqual([200, 201])
    expect(firstConcurrent.body).toMatchObject({
      agentSessionId: "agent-codex-herdman",
      id: "client-session-concurrent"
    })
    expect(secondConcurrent.body).toEqual(firstConcurrent.body)
    expect(agents.creations.filter((creation) => creation[1] === workspaceFolder)).toHaveLength(2)

    expect(await jsonRequest(server, "/v1/sessions")).toMatchObject({
      body: expect.arrayContaining([expect.objectContaining({ id: session.id })])
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { id: session.id }
    })
    expect(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            id: "client-session-id",
            projectId: "missing",
            harnessId: "codex"
          }),
          method: "POST"
        })
      ).status
    ).toBe(404)
    const missingWorkspaceResponse = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({
        folderPath: "/tmp/herdman-missing-session-workspace",
        id: "missing-folder-workspace"
      }),
      method: "POST"
    })
    expect(missingWorkspaceResponse.status).toBe(201)
    expect(
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: "missing-folder-workspace",
          harnessId: "codex"
        }),
        method: "POST"
      })
    ).toEqual({
      body: { error: "Project folder does not exist: /tmp/herdman-missing-session-workspace" },
      status: 400
    })
    expect((await jsonRequest(server, "/v1/sessions/missing")).status).toBe(500)

    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "hello" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === 1)
    expect(agents.prompts).toEqual([[session.agentSessionId, "hello"]])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ clientActionId: "prompt-retry-1", text: "retry once" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ clientActionId: "prompt-retry-1", text: "retry once" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === 2)
    expect(agents.prompts).toEqual([
      [session.agentSessionId, "hello"],
      [session.agentSessionId, "retry once"]
    ])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "raw chunks" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === 3)
    expect(
      (await run(services.db.getSessionDetail(session.id))).conversation.map((item) => item.text)
    ).toEqual(
      expect.arrayContaining([
        "hello",
        "Echo: hello",
        "raw chunks",
        "Raw answer",
        "Raw answer without id"
      ])
    )
    expect(
      (await run(services.db.getSessionDetail(session.id))).conversation.map((item) => [
        item.messageId,
        item.text
      ])
    ).toEqual(expect.arrayContaining([["assistant-raw", "Raw answer"]]))
    expect(await run(services.db.listEvents(0))).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "session.output",
          payload: expect.objectContaining({ sessionUpdate: "agent_message_chunk" })
        })
      ])
    )
    // The per-session history endpoint returns only this session's envelopes.
    const historyResponse = await jsonRequest(server, `/v1/sessions/${session.id}/events`)
    expect(historyResponse.status).toBe(200)
    const history = historyResponse.body as Array<{ subjectId: string; kind: string }>
    expect(history.length).toBeGreaterThan(0)
    expect(history.every((event) => event.subjectId === session.id)).toBe(true)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "returned events" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === 4)
    expect(
      (await run(services.db.getSessionDetail(session.id))).conversation.map((item) => item.text)
    ).toEqual(expect.arrayContaining(["returned events", "Raw answer"]))

    const slowResponse = (
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "slow prompt" }),
        method: "POST"
      })
    ).body as { readonly queueItemId: string }
    expect(slowResponse.queueItemId).toBeTypeOf("string")
    await waitFor(() => agents.prompts.length === 5)
    const queuedResponse = (
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "queued original" }),
        method: "POST"
      })
    ).body as { readonly queueItemId: string }
    const removedResponse = (
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "queued remove" }),
        method: "POST"
      })
    ).body as { readonly queueItemId: string }
    expect((await jsonRequest(server, `/v1/sessions/${session.id}/queue`)).body).toMatchObject([
      { id: queuedResponse.queueItemId, text: "queued original" },
      { id: removedResponse.queueItemId, text: "queued remove" }
    ])
    expect(
      (
        await jsonRequest(
          server,
          `/v1/sessions/${session.id}/queue/${queuedResponse.queueItemId}`,
          {
            body: JSON.stringify({ text: "queued edited" }),
            method: "PATCH"
          }
        )
      ).body
    ).toMatchObject({ text: "queued edited" })
    expect(
      (
        await jsonRequest(
          server,
          `/v1/sessions/${session.id}/queue/${removedResponse.queueItemId}`,
          { method: "DELETE" }
        )
      ).status
    ).toBe(204)
    await waitFor(() => agents.prompts.length === 6)
    expect(agents.prompts).toContainEqual([session.agentSessionId, "queued edited"])
    expect(agents.prompts).not.toContainEqual([session.agentSessionId, "queued remove"])

    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "prompt fails" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(async () =>
      (await run(services.db.listEvents(0))).some((event) => event.kind === "session.error")
    )
    expect(agents.loads).toContainEqual(["codex", session.agentSessionId, workspaceFolder])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/cancel`, {
          body: JSON.stringify({ clientActionId: "cancel-retry-1" }),
          method: "POST"
        })
      ).status
    ).toBe(202)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/cancel`, {
          body: JSON.stringify({ clientActionId: "cancel-retry-1" }),
          method: "POST"
        })
      ).status
    ).toBe(202)
    expect(agents.cancellations).toEqual([session.agentSessionId])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/mode`, {
          body: JSON.stringify({ modeId: "plan" }),
          method: "POST"
        })
      ).body
    ).toEqual({ modeId: "plan" })
    expect(agents.modes).toEqual([[session.agentSessionId, "plan"]])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
          body: JSON.stringify({ configId: "model", value: "gpt-5" }),
          method: "POST"
        })
      ).body
    ).toEqual({ configId: "model" })
    expect(agents.configs).toEqual([[session.agentSessionId, "model", "gpt-5"]])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}`, {
          body: JSON.stringify({ title: "Retitled" }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ isArchived: false, title: "Retitled" })
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}`, {
          body: JSON.stringify({ isArchived: true }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ isArchived: true })
    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}`, { method: "DELETE" })).status
    ).toBe(204)
    expect(
      (await jsonRequest(server, `/v1/projects/${workspace.id}`, { method: "DELETE" })).status
    ).toBe(204)

    expect((await readSseEvents(server, 1)).at(0)).toEqual(
      expect.objectContaining({ kind: "project.created" })
    )
    expect((await readSseEvents(server, 1, "not-a-number")).at(0)).toEqual(
      expect.objectContaining({ kind: "project.created" })
    )
    const replayEvents = await run(services.db.listEvents(0))
    const replayEventCount = replayEvents.length
    const replayCursor = replayEvents.at(-1)?.id ?? 0
    const events = await readSseEvents(server, replayEventCount, 0)
    expect(events).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: "project.created" }),
        expect.objectContaining({ kind: "project.deleted" }),
        expect.objectContaining({ kind: "session.created" }),
        expect.objectContaining({ kind: "session.deleted" })
      ])
    )

    const liveEvent = readSseEvents(server, 1, replayCursor)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/live" }),
      method: "POST"
    })
    expect(await liveEvent).toEqual([expect.objectContaining({ kind: "project.created" })])
    const websocketReplay = await readWebSocketEvents(server, 2, 0)
    expect(websocketReplay).toEqual([
      expect.objectContaining({ kind: "project.created" }),
      expect.objectContaining({ kind: "project.updated" })
    ])
    const socketReplayEvents = await run(services.db.listEvents(0))
    const socketReplayCursor = socketReplayEvents.at(-1)?.id ?? 0
    const websocketLive = readWebSocketEvents(server, 1, socketReplayCursor)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/live-socket" }),
      method: "POST"
    })
    expect(await websocketLive).toEqual([expect.objectContaining({ kind: "project.created" })])

    const legacyWorkspace = await run(
      services.db.createProject({ folderPath: legacyWorkspaceFolder })
    )
    const legacySession = await run(
      services.db.createSession({
        harnessId: "codex",
        id: "legacy-session",
        title: "Legacy session",
        projectId: legacyWorkspace.id
      })
    )
    expect(legacySession.agentSessionId).toBeUndefined()
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${legacySession.id}/prompt`, {
          body: JSON.stringify({ text: "legacy hello" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: legacySession.id })
    await waitFor(() => agents.prompts.some((prompt) => prompt[1] === "legacy hello"))
    expect(agents.prompts).toContainEqual([legacySession.id, "legacy hello"])
    expect(agents.loads).toContainEqual(["codex", legacySession.id, legacyWorkspaceFolder])
  })

  it("persists and fans out agent-initiated events with no prompt in flight", async () => {
    const { agents, server, services } = await start()
    const workspaceRoot = mkdtempSync(join(tmpdir(), "herdman-server-background-"))
    tempDirs.push(workspaceRoot)
    const workspaceFolder = join(workspaceRoot, "herdman")
    mkdirSync(workspaceFolder)
    const workspace = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: workspaceFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: workspace.id, harnessId: "codex", title: "Background" }),
        method: "POST"
      })
    ).body as { readonly id: string; readonly agentSessionId: string }

    // The standing sink was registered at session create; the agent now pushes
    // a whole background turn without any client prompt in flight.
    // Scalar payloads are wrapped rather than crashing materialization.
    await agents.emit(session.agentSessionId, {
      kind: "session.output",
      subjectId: session.agentSessionId,
      payload: "scalar-status-line"
    })
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: { initiatedBy: "agent", turnId: "turn-bg", turnState: "started" }
    })
    await agents.emit(session.agentSessionId, {
      kind: "session.output",
      subjectId: session.agentSessionId,
      payload: {
        content: { text: "Background task finished.", type: "text" },
        messageId: "assistant-bg",
        sessionUpdate: "agent_message_chunk"
      }
    })
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: {
        initiatedBy: "agent",
        stopReason: "end_turn",
        turnId: "turn-bg",
        turnState: "ended"
      }
    })

    const events = await run(services.db.listEvents(0))
    const sessionEvents = events.filter((event) => event.subjectId === session.id)
    expect(sessionEvents).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "session.updated",
          payload: expect.objectContaining({ initiatedBy: "agent", turnState: "started" })
        }),
        expect.objectContaining({
          kind: "session.output",
          payload: expect.objectContaining({ messageId: "assistant-bg" })
        }),
        expect.objectContaining({
          kind: "session.updated",
          payload: expect.objectContaining({ stopReason: "end_turn", turnState: "ended" })
        })
      ])
    )
    const detail = await run(services.db.getSessionDetail(session.id))
    expect(detail.conversation.map((item) => item.text)).toContain("Background task finished.")
  })

  it("keeps subagent-attributed chunks out of the conversation snapshot", async () => {
    const { agents, server, services } = await start()
    const workspaceRoot = mkdtempSync(join(tmpdir(), "herdman-server-subagent-"))
    tempDirs.push(workspaceRoot)
    const workspaceFolder = join(workspaceRoot, "herdman")
    mkdirSync(workspaceFolder)
    const workspace = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: workspaceFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: workspace.id, harnessId: "codex", title: "Subagent" }),
        method: "POST"
      })
    ).body as { readonly id: string; readonly agentSessionId: string }

    await agents.emit(session.agentSessionId, {
      kind: "session.output",
      subjectId: session.agentSessionId,
      payload: {
        content: { text: "main agent text", type: "text" },
        messageId: "assistant-main",
        sessionUpdate: "agent_message_chunk"
      }
    })
    await agents.emit(session.agentSessionId, {
      kind: "session.output",
      subjectId: session.agentSessionId,
      payload: {
        content: { text: "subagent text", type: "text" },
        messageId: "msg-sub-1",
        parentToolCallId: "task-1",
        sessionUpdate: "agent_message_chunk"
      }
    })

    // The raw event is persisted for rich replay (nested transcripts)...
    const events = await run(services.db.listEvents(0))
    expect(events.filter((event) => event.subjectId === session.id)).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "session.output",
          payload: expect.objectContaining({ parentToolCallId: "task-1" })
        })
      ])
    )
    // ...but the text conversation snapshot only carries the main thread.
    const detail = await run(services.db.getSessionDetail(session.id))
    expect(detail.conversation.map((item) => item.text)).toContain("main agent text")
    expect(detail.conversation.map((item) => item.text)).not.toContain("subagent text")
  })

  it("creates worktrees and runs worktree sessions in them", async () => {
    const execFileAsync = promisify(execFile)
    const git = (args: ReadonlyArray<string>, cwd: string) =>
      execFileAsync("git", [...args], { cwd })

    const worktreesRoot = mkdtempSync(join(tmpdir(), "herdman-worktrees-"))
    tempDirs.push(worktreesRoot)
    process.env["HERDMAN_WORKTREES_ROOT"] = worktreesRoot
    try {
      const { agents, server, services } = await start()
      // makeServices' temp dir (the newest entry) holds the server database.
      const serverDatabasePath = join(tempDirs[tempDirs.length - 1] as string, "herdman.sqlite")
      const repoRoot = mkdtempSync(join(tmpdir(), "herdman-repo-"))
      tempDirs.push(repoRoot)
      const repoFolder = join(repoRoot, "repo")
      const plainFolder = join(repoRoot, "plain")
      mkdirSync(repoFolder)
      mkdirSync(plainFolder)
      await git(["init"], repoFolder)
      await git(
        ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
        repoFolder
      )

      const projectResponse = await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: repoFolder, id: "git-project" }),
        method: "POST"
      })
      expect(projectResponse.status).toBe(201)
      expect(projectResponse.body).toMatchObject({
        id: "git-project",
        locations: [{ serverId: "server-a", folderPath: repoFolder, isGitRepository: true }]
      })

      const plainResponse = await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: plainFolder, id: "plain-project" }),
        method: "POST"
      })
      expect(plainResponse.body).toMatchObject({
        locations: [{ isGitRepository: false }]
      })

      // Worktree creation on a non-git project is refused.
      expect(
        (
          await jsonRequest(server, "/v1/projects/plain-project/worktrees", {
            body: JSON.stringify({ name: "nope" }),
            method: "POST"
          })
        ).status
      ).toBe(422)

      // A client-supplied id keys the worktree row and its setup events so
      // callers can follow progress while the create request is in flight.
      const worktreeResponse = await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        body: JSON.stringify({ id: "wt-fix-auth", name: "Fix Auth!" }),
        method: "POST"
      })
      expect(worktreeResponse.status).toBe(201)
      const worktree = worktreeResponse.body as { readonly name: string; readonly path: string }
      expect(worktree).toMatchObject({
        id: "wt-fix-auth",
        projectId: "git-project",
        serverId: "server-a",
        name: "fix-auth",
        branch: "herdman/fix-auth",
        path: join(worktreesRoot, "git-project", "fix-auth")
      })
      expect(existsSync(join(worktree.path, ".git"))).toBe(true)

      // Setup progress was streamed as ordered worktree.setup events: started,
      // git output lines (git narrates "Preparing worktree ..." on stderr),
      // then completed with the elapsed duration.
      const setupPayloads = (await run(services.db.listEvents(0)))
        .filter((event) => event.kind === "worktree.setup" && event.subjectId === "wt-fix-auth")
        .map(
          (event) =>
            event.payload as {
              readonly state: string
              readonly stream?: string
              readonly line?: string
              readonly durationMs?: number
            }
        )
      expect(setupPayloads[0]).toMatchObject({
        state: "started",
        worktreeId: "wt-fix-auth",
        projectId: "git-project",
        name: "fix-auth",
        branch: "herdman/fix-auth"
      })
      const logPayloads = setupPayloads.filter((payload) => payload.state === "log")
      expect(logPayloads.length).toBeGreaterThan(0)
      expect(logPayloads.every((payload) => (payload.line ?? "").length > 0)).toBe(true)
      expect(
        logPayloads.every((payload) => payload.stream === "stdout" || payload.stream === "stderr")
      ).toBe(true)
      const lastSetup = setupPayloads[setupPayloads.length - 1]
      expect(lastSetup?.state).toBe("completed")
      expect(lastSetup?.durationMs).toBeGreaterThanOrEqual(0)

      // Same requested name gets uniquified.
      const secondWorktree = await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        body: JSON.stringify({ name: "fix auth" }),
        method: "POST"
      })
      expect(secondWorktree.body).toMatchObject({
        name: "fix-auth-2",
        branch: "herdman/fix-auth-2"
      })
      // Missing name gets a random memorable slug like "ferocious-walrus".
      const randomNamed = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          method: "POST"
        })
      ).body as { readonly name: string; readonly branch: string }
      expect(randomNamed.name).toMatch(/^[a-z]+-[a-z]+$/)
      expect(randomNamed.branch).toBe(`herdman/${randomNamed.name}`)
      expect(
        ((await jsonRequest(server, "/v1/projects/git-project/worktrees")).body as Array<unknown>)
          .length
      ).toBe(3)

      // A failing git operation (branch already exists) surfaces as 422 and
      // releases the reserved name for a retry.
      await git(["branch", "herdman/doomed"], repoFolder)
      const failed = await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        body: JSON.stringify({ id: "wt-doomed", name: "doomed" }),
        method: "POST"
      })
      expect(failed.status).toBe(422)
      expect((failed.body as { readonly error: string }).error).toContain("doomed")
      // The failure is also published as a terminal worktree.setup event so
      // clients following the stream see what went wrong.
      const failedSetup = (await run(services.db.listEvents(0)))
        .filter((event) => event.kind === "worktree.setup" && event.subjectId === "wt-doomed")
        .map((event) => event.payload as { readonly state: string; readonly message?: string })
      expect(failedSetup[0]?.state).toBe("started")
      const failure = failedSetup[failedSetup.length - 1]
      expect(failure?.state).toBe("failed")
      expect(failure?.message).toContain("doomed")
      expect(
        ((await jsonRequest(server, "/v1/projects/git-project/worktrees")).body as Array<unknown>)
          .length
      ).toBe(3)

      // Sessions created with a worktree run the agent inside the worktree.
      const sessionResponse = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: "git-project",
          harnessId: "codex",
          worktreeName: "fix-auth",
          title: "Worktree chat"
        }),
        method: "POST"
      })
      expect(sessionResponse.status).toBe(201)
      const session = sessionResponse.body as {
        readonly id: string
        readonly agentSessionId: string
        readonly cwd: string
        readonly worktreeName: string
      }
      expect(session.worktreeName).toBe("fix-auth")
      expect(session.cwd).toBe(worktree.path)
      expect(agents.creations).toContainEqual(["codex", worktree.path])

      // Reattaching (prompt after restart) resolves the same worktree cwd.
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "hello worktree" }),
        method: "POST"
      })
      await waitFor(() => agents.prompts.some((prompt) => prompt[1] === "hello worktree"))
      expect(agents.loads).toContainEqual(["codex", session.agentSessionId, worktree.path])

      // Requesting a taken name twice more walks the numeric suffixes.
      await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        body: JSON.stringify({ name: "fix auth" }),
        method: "POST"
      })
      expect(
        (
          await jsonRequest(server, "/v1/projects/git-project/worktrees", {
            body: JSON.stringify({ name: "fix auth" }),
            method: "POST"
          })
        ).body
      ).toMatchObject({ name: "fix-auth-4" })

      // Random draws that collide with existing names are retried.
      const randomSpy = vi.spyOn(Math, "random").mockReturnValue(0)
      try {
        const pinned = await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          method: "POST"
        })
        const pinnedName = (pinned.body as { readonly name: string }).name
        const collided = await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          method: "POST"
        })
        expect((collided.body as { readonly name: string }).name).not.toBe(pinnedName)
      } finally {
        randomSpy.mockRestore()
      }

      // Archiving a session deletes its worktree from disk once no active
      // session still relies on it. Set up a dedicated worktree shared by two
      // sessions plus an unrelated session in another project.
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: "plain-project", harnessId: "codex" }),
        method: "POST"
      })
      const solo = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "solo work" }),
          method: "POST"
        })
      ).body as { readonly name: string; readonly path: string }
      expect(existsSync(solo.path)).toBe(true)
      const worktreeNames = async () =>
        (
          (await jsonRequest(server, "/v1/projects/git-project/worktrees")).body as ReadonlyArray<{
            readonly name: string
          }>
        ).map((entry) => entry.name)
      const soloSession = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: solo.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }
      const sharer = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: solo.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }

      // The worktree survives while another active session still uses it.
      await jsonRequest(server, `/v1/sessions/${soloSession.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      expect(existsSync(solo.path)).toBe(true)
      expect(await worktreeNames()).toContain(solo.name)

      // Archiving the final active session removes it from git and disk.
      await jsonRequest(server, `/v1/sessions/${sharer.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      expect(existsSync(solo.path)).toBe(false)
      expect(await worktreeNames()).not.toContain(solo.name)

      // Re-archiving once the worktree record is gone is a harmless no-op.
      expect(
        (
          await jsonRequest(server, `/v1/sessions/${sharer.id}`, {
            body: JSON.stringify({ isArchived: true }),
            method: "PATCH"
          })
        ).status
      ).toBe(200)

      // Archiving a session that never had a worktree leaves worktrees intact.
      const plainSession = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ projectId: "git-project", harnessId: "codex" }),
          method: "POST"
        })
      ).body as { readonly id: string }
      const before = (await worktreeNames()).length
      await jsonRequest(server, `/v1/sessions/${plainSession.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      expect((await worktreeNames()).length).toBe(before)

      // A recorded worktree whose folder vanished is rejected too.
      rmSync(worktree.path, { force: true, recursive: true })
      await git(["worktree", "prune"], repoFolder)
      const missingFolder = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: "git-project",
          harnessId: "codex",
          worktreeName: "fix-auth",
          title: "Missing worktree"
        }),
        method: "POST"
      })
      expect(missingFolder.status).toBe(400)
      expect((missingFolder.body as { readonly error: string }).error).toContain(
        "Worktree folder does not exist"
      )

      // A project whose only folder lives on another machine can't host
      // sessions here.
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: join(repoRoot, "detached"), id: "detached-project" }),
        method: "POST"
      })
      const sqlite = new Database(serverDatabasePath)
      sqlite
        .prepare("update project_locations set server_id = 'server-elsewhere' where project_id = ?")
        .run("detached-project")
      sqlite.close()
      const detached = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: "detached-project", harnessId: "codex" }),
        method: "POST"
      })
      expect(detached.status).toBe(400)
      expect((detached.body as { readonly error: string }).error).toContain(
        "no folder on this machine"
      )

      // Unknown worktree names are rejected.
      expect(
        (
          await jsonRequest(server, "/v1/sessions", {
            body: JSON.stringify({
              projectId: "git-project",
              harnessId: "codex",
              worktreeName: "does-not-exist"
            }),
            method: "POST"
          })
        ).status
      ).toBe(400)
    } finally {
      delete process.env["HERDMAN_WORKTREES_ROOT"]
    }
  })

  it("stores files and threads prompt attachments end to end", async () => {
    const { agents, server, services } = await start()
    const projectRoot = mkdtempSync(join(tmpdir(), "herdman-server-attachments-"))
    tempDirs.push(projectRoot)
    const projectFolder = join(projectRoot, "project")
    mkdirSync(projectFolder)

    const upload = async (
      body: Uint8Array,
      options: { name?: string; contentType?: string } = {}
    ) => {
      const query = options.name === undefined ? "" : `?name=${encodeURIComponent(options.name)}`
      const response = await fetch(`${server.url}/v1/files${query}`, {
        body: body as unknown as BodyInit,
        headers: options.contentType === undefined ? {} : { "Content-Type": options.contentType },
        method: "POST"
      })
      return { body: (await response.json()) as Record<string, unknown>, status: response.status }
    }

    // Kind is sniffed from magic bytes, with the declared mime as fallback.
    const pngBytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])
    const png = await upload(pngBytes, { contentType: "image/png", name: "shot.png" })
    expect(png.status).toBe(201)
    expect(png.body).toMatchObject({
      kind: "image",
      mimeType: "image/png",
      name: "shot.png",
      sizeBytes: pngBytes.byteLength
    })
    const jpeg = await upload(Buffer.from([0xff, 0xd8, 0xff, 0xe0, 9, 9]), { name: "raw.bin" })
    expect(jpeg.body).toMatchObject({ kind: "image", mimeType: "application/octet-stream" })
    const gif = await upload(Buffer.from("GIF89a-data"), { contentType: "image/gif" })
    expect(gif.body).toMatchObject({ kind: "image" })
    const webpBytes = Buffer.concat([
      Buffer.from("RIFF"),
      Buffer.from([16, 0, 0, 0]),
      Buffer.from("WEBPVP8 ")
    ])
    expect((await upload(webpBytes, { contentType: "video/webm" })).body).toMatchObject({
      kind: "image"
    })
    const svg = await upload(Buffer.from("<svg/>"), {
      contentType: "image/svg+xml; charset=utf-8",
      name: "../evil/pic.svg"
    })
    expect(svg.body).toMatchObject({
      kind: "image",
      mimeType: "image/svg+xml",
      name: "_evil_pic.svg"
    })
    const text = await upload(Buffer.from("hello"), { contentType: "text/plain", name: "..." })
    expect(text.body).toMatchObject({ kind: "file", mimeType: "text/plain", name: "attachment" })

    // Download round-trips bytes with immutable caching; unknown ids 404.
    const download = await fetch(`${server.url}/v1/files/${String(png.body.id)}`)
    expect(download.status).toBe(200)
    expect(download.headers.get("content-type")).toBe("image/png")
    expect(download.headers.get("cache-control")).toContain("immutable")
    expect(Buffer.from(await download.arrayBuffer()).equals(pngBytes)).toBe(true)
    expect((await fetch(`${server.url}/v1/files/missing-file`)).status).toBe(404)

    // Oversized uploads abort with 413.
    const oversized = await fetch(`${server.url}/v1/files`, {
      body: Buffer.alloc(25 * 1024 * 1024 + 1),
      method: "POST"
    })
    expect(oversized.status).toBe(413)

    const sessionResponse = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        projectId: (
          (
            await jsonRequest(server, "/v1/projects", {
              body: JSON.stringify({ folderPath: projectFolder, id: "attachment-project" }),
              method: "POST"
            })
          ).body as { readonly id: string }
        ).id,
        harnessId: "codex"
      }),
      method: "POST"
    })
    const session = sessionResponse.body as { readonly id: string }

    const pngRef = {
      fileId: String(png.body.id),
      kind: "image" as const,
      mimeType: "image/png",
      name: "shot.png",
      sizeBytes: pngBytes.byteLength
    }
    const textRef = {
      fileId: String(text.body.id),
      kind: "file" as const,
      mimeType: "text/plain",
      name: "attachment",
      sizeBytes: 5
    }

    // Unknown file ids and over-limit attachment counts fail at send time.
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({
            attachments: [{ ...pngRef, fileId: "missing-file" }],
            text: "nope"
          }),
          method: "POST"
        })
      ).status
    ).toBe(422)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ attachments: Array(11).fill(pngRef), text: "too many" }),
          method: "POST"
        })
      ).status
    ).toBe(422)

    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ attachments: [pngRef, textRef], text: "look at these" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true })
    await waitFor(() => agents.prompts.length === 1)
    const promptInput = agents.prompts[0]?.[1]
    expect(promptInput).toMatchObject({
      attachments: [
        { kind: "image", mimeType: "image/png", name: "shot.png" },
        { kind: "file", mimeType: "text/plain", name: "attachment" }
      ],
      text: "look at these"
    })
    const materialized = (promptInput as { attachments: ReadonlyArray<{ path: string }> })
      .attachments[0]?.path
    expect(materialized).toBeTruthy()
    expect(readFileSync(String(materialized)).equals(pngBytes)).toBe(true)

    // Re-sending the same attachment reuses the materialized temp file.
    await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ attachments: [pngRef], text: "again" }),
      method: "POST"
    })
    await waitFor(() => agents.prompts.length === 2)

    // The persisted user message and its replayed event both carry the refs.
    const detail = (await jsonRequest(server, `/v1/sessions/${session.id}`)).body as {
      readonly conversation: ReadonlyArray<{
        readonly text: string
        readonly attachments?: ReadonlyArray<{ readonly fileId: string }>
      }>
    }
    const userItem = detail.conversation.find((item) => item.text === "look at these")
    expect(userItem?.attachments).toMatchObject([
      { fileId: pngRef.fileId },
      { fileId: textRef.fileId }
    ])
    const history = (await jsonRequest(server, `/v1/sessions/${session.id}/events`))
      .body as ReadonlyArray<{ readonly payload: Record<string, unknown> }>
    expect(
      history.some(
        (event) =>
          event.payload.text === "look at these" && Array.isArray(event.payload.attachments)
      )
    ).toBe(true)

    // A queued attachment whose file has vanished surfaces a session error at
    // drain time instead of crashing the queue.
    await run(
      services.db.createPromptQueueItem(session.id, "stale file", [
        { ...pngRef, fileId: "vanished-file" }
      ])
    )
    await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ text: "after stale" }),
      method: "POST"
    })
    await waitFor(async () => {
      const events = (await jsonRequest(server, `/v1/sessions/${session.id}/events`))
        .body as ReadonlyArray<{ readonly kind: string; readonly payload: Record<string, unknown> }>
      return events.some(
        (event) =>
          event.kind === "session.error" && String(event.payload.message).includes("vanished-file")
      )
    })

    // A user payload with malformed attachments is not a conversation item.
    const agentSessionId = agents.prompts[0]?.[0] as string
    await agents.emit(agentSessionId, {
      kind: "session.output",
      payload: { attachments: "bogus", role: "user", text: "malformed" },
      subjectId: agentSessionId
    })
    await waitFor(async () => {
      const events = (await jsonRequest(server, `/v1/sessions/${session.id}/events`))
        .body as ReadonlyArray<{ readonly payload: Record<string, unknown> }>
      return events.some((event) => event.payload.text === "malformed")
    })
    const refreshed = (await jsonRequest(server, `/v1/sessions/${session.id}`)).body as {
      readonly conversation: ReadonlyArray<{ readonly text: string }>
    }
    expect(refreshed.conversation.some((item) => item.text === "malformed")).toBe(false)
  })

  it("sweeps stale materialized attachment temp files at startup", async () => {
    const root = join(tmpdir(), "herdman-attachments")
    mkdirSync(root, { recursive: true })
    const stale = join(root, "sweep-test-stale")
    const fresh = join(root, "sweep-test-fresh")
    mkdirSync(stale, { recursive: true })
    mkdirSync(fresh, { recursive: true })
    const old = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000)
    utimesSync(stale, old, old)

    sweepAttachmentTempFiles()
    expect(existsSync(stale)).toBe(false)
    expect(existsSync(fresh)).toBe(true)

    // A missing temp root is a no-op, not an error.
    rmSync(root, { force: true, recursive: true })
    sweepAttachmentTempFiles(Date.now())
    expect(existsSync(root)).toBe(false)
  })

  it("kills a session's terminal over the delete route", async () => {
    const { server, spawner } = await start()

    // No live terminal for the session yet.
    const missing = await jsonRequest(server, "/v1/terminals/session/no-such-session", {
      method: "DELETE"
    })
    expect(missing.status).toBe(404)
    expect(missing.body).toEqual({ closed: false })

    await jsonRequest(server, "/v1/terminals", {
      body: JSON.stringify({ sessionId: "session-kill", cwd: "/tmp/herdman", cols: 80, rows: 24 }),
      method: "POST"
    })
    const closed = await jsonRequest(server, "/v1/terminals/session/session-kill", {
      method: "DELETE"
    })
    expect(closed.status).toBe(200)
    expect(closed.body).toEqual({ closed: true })
    expect(spawner.processes[0]?.killCount).toBe(1)
  })

  it("bridges terminal create and websocket traffic", async () => {
    const { server, spawner } = await start()
    const terminalResponse = await jsonRequest(server, "/v1/terminals", {
      body: JSON.stringify({ sessionId: "session-1", cwd: "/tmp/herdman", cols: 80, rows: 24 }),
      method: "POST"
    })
    expect((await jsonRequest(server, "/v1/terminals", { method: "POST" })).status).toBe(400)
    const terminal = terminalResponse.body as {
      readonly terminalId: string
      readonly websocketPath: string
    }
    const webSocket = new WebSocket(
      `${server.url.replace("http:", "ws:")}${terminal.websocketPath}?lastOutputSeq=0`
    )
    const messages: Array<unknown> = []

    await new Promise<void>((resolve, reject) => {
      webSocket.once("open", resolve)
      webSocket.once("error", reject)
    })
    webSocket.on("message", (data) => messages.push(JSON.parse(data.toString()) as unknown))
    await new Promise((resolve) => setTimeout(resolve, 20))
    webSocket.send("{")
    await waitFor(() => messages.length === 1)
    webSocket.send(
      JSON.stringify({ type: "input", clientId: "client-a", clientSeq: 1, data: "pwd\n" })
    )
    webSocket.send(
      JSON.stringify({ type: "resize", clientId: "client-a", clientSeq: 2, cols: 120, rows: 30 })
    )
    await waitFor(
      () => spawner.processes[0]?.writes.length === 1 && spawner.processes[0]?.resizes.length === 1,
      () =>
        JSON.stringify({
          processCount: spawner.processes.length,
          resizes: spawner.processes[0]?.resizes ?? [],
          writes: spawner.processes[0]?.writes ?? []
        })
    )
    spawner.handlers[0]?.onOutput("terminal-output")
    spawner.handlers[0]?.onExit(0)

    await waitFor(
      () => messages.length === 3,
      () =>
        JSON.stringify({
          messages,
          processCount: spawner.processes.length,
          readyState: webSocket.readyState,
          writes: spawner.processes[0]?.writes ?? []
        })
    )
    webSocket.send(
      JSON.stringify({ type: "input", clientId: "client-a", clientSeq: 3, data: "after-exit" })
    )
    await waitFor(() => messages.length === 4)
    webSocket.close()

    expect(spawner.processes[0]?.writes).toEqual(["pwd\n"])
    expect(spawner.processes[0]?.resizes).toEqual([[120, 30]])
    expect(messages).toEqual([
      expect.objectContaining({ type: "error" }),
      { type: "output", seq: 1, data: "terminal-output" },
      { type: "exit", seq: 2, exitCode: 0 },
      expect.objectContaining({ type: "error" })
    ])

    const replaySocket = new WebSocket(
      `${server.url.replace("http:", "ws:")}${terminal.websocketPath}?lastOutputSeq=not-a-number`
    )
    const replayMessages: Array<unknown> = []
    replaySocket.on("message", (data) =>
      replayMessages.push(JSON.parse(data.toString()) as unknown)
    )
    await new Promise<void>((resolve, reject) => {
      replaySocket.once("open", resolve)
      replaySocket.once("error", reject)
    })
    await waitFor(() => replayMessages.length === 2)
    expect(replayMessages).toEqual([
      { type: "output", seq: 1, data: "terminal-output" },
      { type: "exit", seq: 2, exitCode: 0 }
    ])
    replaySocket.close()

    const cursorReplaySocket = new WebSocket(
      `${server.url.replace("http:", "ws:")}${terminal.websocketPath}?lastOutputSeq=1`
    )
    const cursorReplayMessages: Array<unknown> = []
    cursorReplaySocket.on("message", (data) =>
      cursorReplayMessages.push(JSON.parse(data.toString()) as unknown)
    )
    await new Promise<void>((resolve, reject) => {
      cursorReplaySocket.once("open", resolve)
      cursorReplaySocket.once("error", reject)
    })
    await waitFor(() => cursorReplayMessages.length === 1)
    expect(cursorReplayMessages).toEqual([{ type: "exit", seq: 2, exitCode: 0 }])
    cursorReplaySocket.close()

    const missingSocket = new WebSocket(
      `${server.url.replace("http:", "ws:")}/v1/terminals/missing/socket`
    )
    const missingMessages: Array<unknown> = []
    missingSocket.on("message", (data) =>
      missingMessages.push(JSON.parse(data.toString()) as unknown)
    )
    await new Promise<void>((resolve, reject) => {
      missingSocket.once("open", resolve)
      missingSocket.once("error", reject)
    })
    await waitFor(() => missingMessages.length === 1)
    expect(missingMessages[0]).toMatchObject({ type: "error" })
    missingSocket.close()

    const badPathSocket = new WebSocket(`${server.url.replace("http:", "ws:")}/v1/not-a-terminal`)
    await new Promise<void>((resolve) => {
      badPathSocket.once("close", resolve)
      badPathSocket.once("error", () => resolve())
    })
  })

  it("buffers event websocket fanout that arrives during replay", async () => {
    const { services } = await makeServices("server-a")
    const fanout = await run(makeEventFanout)
    const replayEvent = {
      createdAt: "2026-06-30T00:00:00.000Z",
      id: 1,
      kind: "project.created" as const,
      payload: { id: "replay" },
      serverId: "server-a",
      subjectId: "replay"
    }
    const liveEvent = {
      createdAt: "2026-06-30T00:00:01.000Z",
      id: 2,
      kind: "project.updated" as const,
      payload: { id: "live" },
      serverId: "server-a",
      subjectId: "live"
    }
    const server = await startWithApp(
      {
        ...services,
        db: {
          ...services.db,
          listEvents: () =>
            Effect.promise(async () => {
              await run(fanout.publish(liveEvent))
              return [replayEvent]
            })
        }
      },
      fanout
    )
    runningServers.push(server)

    expect(await readWebSocketEvents(server, 2, 0)).toEqual([replayEvent, liveEvent])
    expect(await readWebSocketEvents(server, 1, 1)).toEqual([liveEvent])
    expect(await readWebSocketEvents(server, 2, Number.MAX_SAFE_INTEGER)).toEqual([
      replayEvent,
      liveEvent
    ])
  })

  it("exposes an Effect service layer and EventFanout subscription", async () => {
    const { services } = await makeServices("layered")
    const layered = await run(
      Effect.gen(function* () {
        const server = yield* HerdManServer
        return yield* server.db.getUpdateInfo
      }).pipe(Effect.provide(HerdManServer.layer(services)))
    )
    expect(layered.currentVersion).toBe("0.1.0")

    const fanout = await run(makeEventFanout)
    const events: Array<unknown> = []
    const unsubscribe = fanout.subscribe((event) => events.push(event))
    await run(
      fanout.publish({
        createdAt: "2026-06-30T00:00:00.000Z",
        id: 1,
        kind: "update.changed",
        payload: {},
        serverId: "server-a",
        subjectId: "update"
      })
    )
    unsubscribe()
    expect(events).toHaveLength(1)
  })
})
