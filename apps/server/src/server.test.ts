import type { AcpRuntimeService } from "@herdman/acp-runtime"
import type { Harness } from "@herdman/api"
import { makeDatabase, type HerdManDatabaseService } from "@herdman/db"
import type {
  TerminalHandlers,
  TerminalProcess,
  TerminalSpawnRequest,
  TerminalSpawner
} from "@herdman/terminal"
import { makeTerminalManager } from "@herdman/terminal"
import { Effect } from "effect"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { WebSocket } from "ws"
import { afterEach, describe, expect, it } from "vitest"
import {
  defaultDatabasePath,
  defaultServerConfig,
  HerdManServer,
  makeEventFanout,
  startHerdManServer,
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

const makeAcp = (): AcpRuntimeService & {
  readonly prompts: Array<readonly [string, string]>
  readonly cancellations: Array<string>
  readonly modes: Array<readonly [string, string]>
  readonly configs: Array<readonly [string, string, string]>
} => {
  const prompts: Array<readonly [string, string]> = []
  const cancellations: Array<string> = []
  const modes: Array<readonly [string, string]> = []
  const configs: Array<readonly [string, string, string]> = []
  return {
    prompts,
    cancellations,
    modes,
    configs,
    discoverHarnesses: Effect.succeed(harnesses),
    createAgentSession: (harnessId, cwd) =>
      Effect.succeed(`agent-${harnessId}-${cwd.split("/").at(-1) ?? "root"}`),
    loadAgentSession: (_harnessId, agentSessionId) => Effect.succeed(agentSessionId),
    prompt: (sessionId, text) =>
      Effect.sync(() => {
        prompts.push([sessionId, text])
        return {
          stopReason: "end_turn" as const,
          events: [
            {
              kind: "session.output" as const,
              subjectId: sessionId,
              payload: { role: "assistant", text: `Echo: ${text}` }
            }
          ]
        }
      }),
    cancel: (sessionId) =>
      Effect.sync(() => {
        cancellations.push(sessionId)
        return {
          kind: "session.updated" as const,
          subjectId: sessionId,
          payload: "cancelled"
        }
      }),
    setMode: (sessionId, modeId) =>
      Effect.sync(() => {
        modes.push([sessionId, modeId])
        return {
          kind: "session.updated" as const,
          subjectId: sessionId,
          payload: { modeId }
        }
      }),
    setConfigOption: (sessionId, configId, value) =>
      Effect.sync(() => {
        configs.push([sessionId, configId, value])
        return {
          kind: "session.updated" as const,
          subjectId: sessionId,
          payload: { configId, value }
        }
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
  const acp = makeAcp()
  return {
    acp,
    services: {
      acp,
      db,
      terminal: makeTerminalManager({ defaultShell: "/bin/sh", env: {}, spawner })
    },
    spawner
  }
}

const start = async (auth = { allowLocalhostWithoutAuth: true, requireBearerToken: false }) => {
  const { acp, services, spawner } = await makeServices("server-a")
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
  return { acp, server, services, spawner }
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

const waitFor = async (
  predicate: () => boolean,
  describeState: () => string = () => ""
): Promise<void> => {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (predicate()) {
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
      port: 8765,
      version: "0.1.0"
    })
    expect(
      (await jsonRequest(server, "/v1/auth/pairing-token", { method: "POST" })).body
    ).toMatchObject({
      token: expect.stringMatching(/^hm_/)
    })
    expect(defaultDatabasePath()).toContain("herdman-server.sqlite")

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

  it("manages workspaces, harnesses, sessions, actions, and event replay", async () => {
    const { acp, server, services } = await start()
    const badJson = await fetch(`${server.url}/v1/workspaces`, {
      body: "{",
      headers: { "Content-Type": "application/json" },
      method: "POST"
    })
    expect(badJson.status).toBe(400)
    expect((await jsonRequest(server, "/v1/missing")).status).toBe(404)

    const workspaceResponse = await jsonRequest(server, "/v1/workspaces", {
      body: JSON.stringify({ folderPath: "/tmp/herdman", id: "workspace-client-id" }),
      method: "POST"
    })
    expect(workspaceResponse.status).toBe(201)
    const workspace = workspaceResponse.body as { readonly id: string }
    expect(workspace.id).toBe("workspace-client-id")
    expect((await jsonRequest(server, "/v1/workspaces")).body).toMatchObject([{ id: workspace.id }])
    expect(
      (
        await jsonRequest(server, `/v1/workspaces/${workspace.id}`, {
          body: JSON.stringify({ name: "Renamed" }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ name: "Renamed" })

    expect((await jsonRequest(server, "/v1/harnesses")).body).toMatchObject([
      { id: "codex", enabled: true }
    ])
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
      body: JSON.stringify({ workspaceId: workspace.id, harnessId: "codex", title: "First chat" }),
      method: "POST"
    })
    const session = sessionResponse.body as { readonly id: string; readonly agentSessionId: string }
    expect(session.agentSessionId).toBe("agent-codex-herdman")
    expect((await jsonRequest(server, "/v1/sessions")).body).toMatchObject([{ id: session.id }])
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { id: session.id }
    })
    expect(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ workspaceId: "missing", harnessId: "codex" }),
          method: "POST"
        })
      ).status
    ).toBe(404)
    expect((await jsonRequest(server, "/v1/sessions/missing")).status).toBe(500)

    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "hello" }),
          method: "POST"
        })
      ).body
    ).toEqual({ stopReason: "end_turn" })
    expect(acp.prompts).toEqual([[session.agentSessionId, "hello"]])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/cancel`, {
          body: JSON.stringify({}),
          method: "POST"
        })
      ).status
    ).toBe(202)
    expect(acp.cancellations).toEqual([session.agentSessionId])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/mode`, {
          body: JSON.stringify({ modeId: "plan" }),
          method: "POST"
        })
      ).body
    ).toEqual({ modeId: "plan" })
    expect(acp.modes).toEqual([[session.agentSessionId, "plan"]])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
          body: JSON.stringify({ configId: "model", value: "gpt-5" }),
          method: "POST"
        })
      ).body
    ).toEqual({ configId: "model" })
    expect(acp.configs).toEqual([[session.agentSessionId, "model", "gpt-5"]])
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
      (await jsonRequest(server, `/v1/workspaces/${workspace.id}`, { method: "DELETE" })).status
    ).toBe(204)

    expect(await readSseEvents(server, 1)).toEqual([
      expect.objectContaining({ kind: "workspace.created" })
    ])
    expect(await readSseEvents(server, 1, "not-a-number")).toEqual([
      expect.objectContaining({ kind: "workspace.created" })
    ])
    const events = await readSseEvents(server, 11, 0)
    expect(events).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: "workspace.created" }),
        expect.objectContaining({ kind: "workspace.deleted" }),
        expect.objectContaining({ kind: "session.created" }),
        expect.objectContaining({ kind: "session.deleted" })
      ])
    )

    const liveEvent = readSseEvents(server, 1, 11)
    await jsonRequest(server, "/v1/workspaces", {
      body: JSON.stringify({ folderPath: "/tmp/live" }),
      method: "POST"
    })
    expect(await liveEvent).toEqual([expect.objectContaining({ kind: "workspace.created" })])

    const legacyWorkspace = await run(
      services.db.createWorkspace({ folderPath: "/tmp/legacy-agent-session" })
    )
    const legacySession = await run(
      services.db.createSession({
        harnessId: "codex",
        id: "legacy-session",
        title: "Legacy session",
        workspaceId: legacyWorkspace.id
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
    ).toEqual({ stopReason: "end_turn" })
    expect(acp.prompts).toContainEqual([legacySession.id, "legacy hello"])
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
      `${server.url.replace("http:", "ws:")}${terminal.websocketPath}`
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
    webSocket.send(JSON.stringify({ type: "input", data: "pwd\n" }))
    webSocket.send(JSON.stringify({ type: "resize", cols: 120, rows: 30 }))
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
    webSocket.send(JSON.stringify({ type: "input", data: "after-exit" }))
    await waitFor(() => messages.length === 4)
    webSocket.close()

    expect(spawner.processes[0]?.writes).toEqual(["pwd\n"])
    expect(spawner.processes[0]?.resizes).toEqual([[120, 30]])
    expect(messages).toEqual([
      expect.objectContaining({ type: "error" }),
      { type: "output", data: "terminal-output" },
      { type: "exit", exitCode: 0 },
      expect.objectContaining({ type: "error" })
    ])

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
