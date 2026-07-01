import type { AcpRuntimeService, RuntimeEventSink } from "@herdman/acp-runtime"
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
import { createServer } from "node:http"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { WebSocket } from "ws"
import { afterEach, describe, expect, it } from "vitest"
import {
  defaultDatabasePath,
  defaultServerConfig,
  EventFanout,
  HerdManServer,
  makeHerdManServerApp,
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
  readonly loads: Array<readonly [string, string, string]>
  readonly prompts: Array<readonly [string, string]>
  readonly cancellations: Array<string>
  readonly modes: Array<readonly [string, string]>
  readonly configs: Array<readonly [string, string, string]>
  readonly inspections: Array<readonly [string, string]>
  readonly creations: Array<readonly [string, string]>
} => {
  const loads: Array<readonly [string, string, string]> = []
  const prompts: Array<readonly [string, string]> = []
  const cancellations: Array<string> = []
  const modes: Array<readonly [string, string]> = []
  const configs: Array<readonly [string, string, string]> = []
  const inspections: Array<readonly [string, string]> = []
  const creations: Array<readonly [string, string]> = []
  return {
    loads,
    prompts,
    cancellations,
    modes,
    configs,
    inspections,
    creations,
    discoverHarnesses: Effect.succeed(harnesses),
    createAgentSession: (harnessId, cwd) =>
      Effect.promise(
        () =>
          new Promise<string>((resolve) => {
            creations.push([harnessId, cwd])
            setTimeout(() => resolve(`agent-${harnessId}-${cwd.split("/").at(-1) ?? "root"}`), 5)
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
    loadAgentSession: (harnessId, agentSessionId, cwd) =>
      Effect.sync(() => {
        loads.push([harnessId, agentSessionId, cwd])
        return agentSessionId
      }),
    prompt: (sessionId, text, onEvent?: RuntimeEventSink) =>
      Effect.promise(async () => {
        prompts.push([sessionId, text])
        if (text === "prompt fails") {
          throw new Error("prompt failed")
        }
        const events =
          text === "raw chunks" || text === "returned events"
            ? [
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { text, type: "text" },
                    sessionUpdate: "user_message_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { text: "Raw answer", type: "text" },
                    sessionUpdate: "agent_message_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { text: "thought", type: "text" },
                    sessionUpdate: "agent_thought_chunk"
                  }
                },
                {
                  kind: "session.output" as const,
                  subjectId: sessionId,
                  payload: {
                    content: { type: "image" },
                    sessionUpdate: "agent_message_chunk"
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
        if (text !== "returned events") {
          for (const event of events) {
            await onEvent?.(event)
          }
        }
        return {
          stopReason: "end_turn" as const,
          events: onEvent === undefined || text === "returned events" ? events : []
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
    const badJson = await fetch(`${server.url}/v1/workspaces`, {
      body: "{",
      headers: { "Content-Type": "application/json" },
      method: "POST"
    })
    expect(badJson.status).toBe(400)
    expect((await jsonRequest(server, "/v1/missing")).status).toBe(404)

    const workspaceResponse = await jsonRequest(server, "/v1/workspaces", {
      body: JSON.stringify({ folderPath: workspaceFolder, id: "workspace-client-id" }),
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
    expect(acp.inspections).toEqual([["codex", workspaceFolder]])
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
    expect(acp.inspections.at(-1)).toEqual(["codex", tmpdir()])
    expect(
      (await jsonRequest(server, `/v1/capabilities?cwd=${encodeURIComponent(cwdFile)}`)).body
    ).toMatchObject({
      harnesses: [{ harness: { id: "codex" } }]
    })
    expect(acp.inspections.at(-1)).toEqual(["codex", tmpdir()])
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
      body: JSON.stringify({ workspaceId: workspace.id, harnessId: "codex", title: "First chat" }),
      method: "POST"
    })
    const session = sessionResponse.body as { readonly id: string; readonly agentSessionId: string }
    expect(session.agentSessionId).toBe("agent-codex-herdman")
    expect(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            id: session.id,
            workspaceId: workspace.id,
            harnessId: "codex",
            title: "First chat"
          }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ agentSessionId: "agent-codex-herdman", id: session.id })

    const concurrentSessionBody = JSON.stringify({
      id: "client-session-concurrent",
      workspaceId: workspace.id,
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
    expect(acp.creations.filter((creation) => creation[1] === workspaceFolder)).toHaveLength(2)

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
            workspaceId: "missing",
            harnessId: "codex"
          }),
          method: "POST"
        })
      ).status
    ).toBe(404)
    const missingWorkspaceResponse = await jsonRequest(server, "/v1/workspaces", {
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
          workspaceId: "missing-folder-workspace",
          harnessId: "codex"
        }),
        method: "POST"
      })
    ).toEqual({
      body: { error: "Workspace folder does not exist: /tmp/herdman-missing-session-workspace" },
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
    ).toEqual({ accepted: true, sessionId: session.id })
    await waitFor(() => acp.prompts.length === 1)
    expect(acp.prompts).toEqual([[session.agentSessionId, "hello"]])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ clientActionId: "prompt-retry-1", text: "retry once" }),
          method: "POST"
        })
      ).body
    ).toEqual({ accepted: true, sessionId: session.id })
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ clientActionId: "prompt-retry-1", text: "retry once" }),
          method: "POST"
        })
      ).body
    ).toEqual({ accepted: true, sessionId: session.id })
    await waitFor(() => acp.prompts.length === 2)
    expect(acp.prompts).toEqual([
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
    ).toEqual({ accepted: true, sessionId: session.id })
    await waitFor(() => acp.prompts.length === 3)
    expect(
      (await run(services.db.getSessionDetail(session.id))).conversation.map((item) => item.text)
    ).toEqual(expect.arrayContaining(["hello", "Echo: hello", "raw chunks", "Raw answer"]))
    expect(await run(services.db.listEvents(0))).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "session.output",
          payload: expect.objectContaining({ sessionUpdate: "agent_message_chunk" })
        })
      ])
    )
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "returned events" }),
          method: "POST"
        })
      ).body
    ).toEqual({ accepted: true, sessionId: session.id })
    await waitFor(() => acp.prompts.length === 4)
    expect(
      (await run(services.db.getSessionDetail(session.id))).conversation.map((item) => item.text)
    ).toEqual(expect.arrayContaining(["returned events", "Raw answer"]))
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "prompt fails" }),
          method: "POST"
        })
      ).body
    ).toEqual({ accepted: true, sessionId: session.id })
    await waitFor(async () =>
      (await run(services.db.listEvents(0))).some((event) => event.kind === "session.error")
    )
    expect(acp.loads).toContainEqual(["codex", session.agentSessionId, workspaceFolder])
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
    const replayEvents = await run(services.db.listEvents(0))
    const replayEventCount = replayEvents.length
    const replayCursor = replayEvents.at(-1)?.id ?? 0
    const events = await readSseEvents(server, replayEventCount, 0)
    expect(events).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: "workspace.created" }),
        expect.objectContaining({ kind: "workspace.deleted" }),
        expect.objectContaining({ kind: "session.created" }),
        expect.objectContaining({ kind: "session.deleted" })
      ])
    )

    const liveEvent = readSseEvents(server, 1, replayCursor)
    await jsonRequest(server, "/v1/workspaces", {
      body: JSON.stringify({ folderPath: "/tmp/live" }),
      method: "POST"
    })
    expect(await liveEvent).toEqual([expect.objectContaining({ kind: "workspace.created" })])
    const websocketReplay = await readWebSocketEvents(server, 2, 0)
    expect(websocketReplay).toEqual([
      expect.objectContaining({ kind: "workspace.created" }),
      expect.objectContaining({ kind: "workspace.updated" })
    ])
    const socketReplayEvents = await run(services.db.listEvents(0))
    const socketReplayCursor = socketReplayEvents.at(-1)?.id ?? 0
    const websocketLive = readWebSocketEvents(server, 1, socketReplayCursor)
    await jsonRequest(server, "/v1/workspaces", {
      body: JSON.stringify({ folderPath: "/tmp/live-socket" }),
      method: "POST"
    })
    expect(await websocketLive).toEqual([expect.objectContaining({ kind: "workspace.created" })])

    const legacyWorkspace = await run(
      services.db.createWorkspace({ folderPath: legacyWorkspaceFolder })
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
    ).toEqual({ accepted: true, sessionId: legacySession.id })
    await waitFor(() => acp.prompts.some((prompt) => prompt[1] === "legacy hello"))
    expect(acp.prompts).toContainEqual([legacySession.id, "legacy hello"])
    expect(acp.loads).toContainEqual(["codex", legacySession.id, legacyWorkspaceFolder])
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
      kind: "workspace.created" as const,
      payload: { id: "replay" },
      serverId: "server-a",
      subjectId: "replay"
    }
    const liveEvent = {
      createdAt: "2026-06-30T00:00:01.000Z",
      id: 2,
      kind: "workspace.updated" as const,
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
