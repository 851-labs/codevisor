import {
  harnessCatalog,
  type AgentRuntimeService,
  type PromptInput,
  type QuestionAnswer,
  type RuntimeEvent,
  type RuntimeEventSink,
  type SetGoalUpdate
} from "@codevisor/agent-runtime"
import type {
  Harness,
  McpServer,
  NativeMcpScan,
  SessionConfigOption,
  SkillsScan
} from "@codevisor/api"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import Database from "better-sqlite3"
import type {
  TerminalHandlers,
  TerminalProcess,
  TerminalSpawnRequest,
  TerminalSpawner
} from "@codevisor/terminal"
import { makeTerminalManager, TerminalError } from "@codevisor/terminal"
import { Effect } from "effect"
import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { createServer } from "node:http"
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  utimesSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { promisify } from "node:util"
import { WebSocket } from "ws"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  defaultDatabasePath,
  defaultServerConfig,
  EventFanout,
  CodevisorServer,
  makeCodevisorServerApp,
  makeEventFanout,
  reconcileOrphanedSessionTurns,
  startCodevisorServer,
  sweepAttachmentTempFiles,
  type RunningCodevisorServer
} from "./server.js"
import type { HarnessAuthManager } from "./harness-auth.js"
import type { CodevisorServerServices } from "./server.js"
import { NativeMcpError } from "./native-mcp-manager.js"
import { SkillsError } from "./skills-manager.js"
import { productionFoodWorktreeNames } from "./worktree-names.js"
import { foodWorktreeNames } from "./food-worktree-names.js"
import { boundedMcpTimerDelay, makeMcpManager, NodeStreamableHttpTransport } from "./mcp-manager.js"
import { Client as McpClient } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import type { Transport as McpTransport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { ToolListChangedNotificationSchema } from "@modelcontextprotocol/sdk/types.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const configSelectionsFromTestOptions = (
  options: ReadonlyArray<SessionConfigOption>
): Readonly<Record<string, string>> =>
  Object.fromEntries(options.map((option) => [option.id, option.currentValue]))

const harnesses: ReadonlyArray<Harness> = [
  {
    id: "codex",
    name: "Codex",
    symbolName: "chevron.left.forwardslash.chevron.right",
    source: "registry",
    launchKind: "npx",
    enabled: true,
    readiness: { state: "ready" },
    installHint: "npm install -g @openai/codex"
  }
]

const makeAgents = (): AgentRuntimeService & {
  readonly loads: Array<readonly [string, string, string]>
  readonly prompts: Array<readonly [string, string | PromptInput]>
  readonly cancellations: Array<string>
  readonly closes: Array<string>
  readonly modes: Array<readonly [string, string]>
  readonly configs: Array<readonly [string, string, string]>
  readonly goals: Array<readonly [string, SetGoalUpdate]>
  readonly goalClears: Array<string>
  readonly questionAnswers: Array<readonly [string, string, QuestionAnswer]>
  readonly inspections: Array<readonly [string, string]>
  readonly creations: Array<readonly [string, string]>
  readonly environmentRefreshes: Array<number>
  readonly sinks: Map<string, RuntimeEventSink>
  readonly emit: (sessionId: string, event: RuntimeEvent) => Promise<void>
} => {
  const loads: Array<readonly [string, string, string]> = []
  const prompts: Array<readonly [string, string | PromptInput]> = []
  const cancellations: Array<string> = []
  const closes: Array<string> = []
  const modes: Array<readonly [string, string]> = []
  const configs: Array<readonly [string, string, string]> = []
  const goals: Array<readonly [string, SetGoalUpdate]> = []
  const goalClears: Array<string> = []
  const questionAnswers: Array<readonly [string, string, QuestionAnswer]> = []
  const inspections: Array<readonly [string, string]> = []
  const creations: Array<readonly [string, string]> = []
  const environmentRefreshes: Array<number> = []
  const sinks = new Map<string, RuntimeEventSink>()
  const configOptionsBySession = new Map<string, ReadonlyArray<SessionConfigOption>>()
  const dependencyConfigSessions = new Set<string>()
  const dependencyConfigOptions = (
    model = "model-default",
    reasoning = "low",
    speed = "standard"
  ): ReadonlyArray<SessionConfigOption> => [
    {
      category: "model",
      currentValue: model,
      id: "model",
      name: "Model",
      options: [
        { name: "Default model", value: "model-default" },
        { name: "Saved model", value: "model-saved" }
      ]
    },
    {
      category: "thought_level",
      currentValue: reasoning,
      id: "reasoning",
      name: "Reasoning",
      options:
        model === "model-saved"
          ? [
              { name: "Low", value: "low" },
              { name: "High", value: "high" }
            ]
          : [{ name: "Low", value: "low" }]
    },
    {
      category: "speed",
      currentValue: speed,
      id: "speed",
      name: "Speed",
      options:
        model === "model-saved"
          ? [
              { name: "Standard", value: "standard" },
              { name: "Fast", value: "fast" }
            ]
          : [{ name: "Standard", value: "standard" }]
    },
    {
      category: "tone",
      currentValue: "brief",
      id: "tone",
      name: "Tone",
      options: [
        {
          group: "response-style",
          name: "Response style",
          options: [
            { name: "Brief", value: "brief" },
            { name: "Detailed", value: "detailed" }
          ]
        }
      ]
    }
  ]
  const emit = async (sessionId: string, event: RuntimeEvent): Promise<void> => {
    await sinks.get(sessionId)?.(event)
  }
  return {
    loads,
    prompts,
    cancellations,
    closes,
    modes,
    configs,
    goals,
    goalClears,
    questionAnswers,
    inspections,
    creations,
    environmentRefreshes,
    sinks,
    emit,
    catalog: harnessCatalog,
    setExtraHarnesses: () => {},
    discoverHarnesses: Effect.succeed(harnesses),
    refreshEnvironment: Effect.sync(() => {
      environmentRefreshes.push(environmentRefreshes.length + 1)
    }),
    listAgentSessions: (harnessId) =>
      Effect.succeed(
        harnessId === "codex"
          ? [{ sessionId: "native-1", cwd: "/repo/native", title: "Old codex chat" }]
          : []
      ),
    readHarnessUsageLimits: (harnessId) =>
      Effect.succeed({
        fetchedAt: "2026-01-01T00:00:00.000Z",
        harnessId,
        state: "unavailable" as const,
        windows: []
      }),
    createAgentSession: (harnessId, cwd, sink) =>
      Effect.promise(
        () =>
          new Promise<string>((resolve) => {
            creations.push([harnessId, cwd])
            const delayMs = cwd.includes("pending-create") ? 100 : 5
            setTimeout(() => {
              const sessionId = `agent-${harnessId}-${cwd.split("/").at(-1) ?? "root"}`
              sinks.set(sessionId, sink)
              resolve(sessionId)
            }, delayMs)
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
          supportsGoals: true,
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
        if (cwd.includes("session-config")) {
          dependencyConfigSessions.add(agentSessionId)
          const configOptions = dependencyConfigOptions()
          configOptionsBySession.set(agentSessionId, configOptions)
          return { configOptions, sessionId: agentSessionId }
        }
        const configOptions: ReadonlyArray<SessionConfigOption> = [
          {
            category: "model",
            currentValue: "gpt-current",
            id: "model",
            name: "Model",
            options: [
              { name: "GPT Current", value: "gpt-current" },
              { name: "GPT New", value: "gpt-new" }
            ]
          }
        ]
        configOptionsBySession.set(agentSessionId, configOptions)
        return {
          configOptions,
          sessionId: agentSessionId
        }
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
        if (text === "token expired") {
          throw new Error("authentication token expired")
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
    closeAgentSession: (sessionId) =>
      Effect.sync(() => {
        closes.push(sessionId)
        sinks.delete(sessionId)
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
        const current = configOptionsBySession.get(sessionId) ?? []
        let configOptions: ReadonlyArray<SessionConfigOption>
        if (dependencyConfigSessions.has(sessionId) && configId === "model") {
          configOptions = dependencyConfigOptions(value)
        } else {
          const option = current.find((candidate) => candidate.id === configId)
          if (dependencyConfigSessions.has(sessionId)) {
            const values =
              option?.options.flatMap((entry) =>
                "value" in entry ? [entry.value] : entry.options.map((nested) => nested.value)
              ) ?? []
            if (!values.includes(value)) {
              throw new Error(`Unsupported ${configId}: ${value}`)
            }
          }
          configOptions = current.map((candidate) =>
            candidate.id === configId ? { ...candidate, currentValue: value } : candidate
          )
        }
        configOptionsBySession.set(sessionId, configOptions)
        await emit(sessionId, {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { configId, configOptions, value }
        })
        return configOptions
      }),
    setGoal: (sessionId, update) =>
      Effect.promise(async () => {
        if (update.objective === "goal fails") {
          throw new Error("Goals are not supported by this harness")
        }
        goals.push([sessionId, update])
        const goal = {
          createdAt: "2026-07-05T00:00:00.000Z",
          objective: update.objective ?? "existing objective",
          status: update.status ?? ("active" as const),
          timeUsedSeconds: 0,
          tokenBudget: update.tokenBudget ?? null,
          tokensUsed: 0,
          updatedAt: "2026-07-05T00:00:00.000Z"
        }
        await emit(sessionId, {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { goal }
        })
        return goal
      }),
    clearGoal: (sessionId) =>
      Effect.promise(async () => {
        goalClears.push(sessionId)
        await emit(sessionId, {
          kind: "session.updated",
          subjectId: sessionId,
          payload: { goalCleared: true }
        })
      }),
    probeHarnessAuth: () => Effect.succeed({ state: "notRequired", methods: [], canLogout: false }),
    authenticateHarness: () => Effect.void,
    logoutHarness: () => Effect.void,
    answerQuestion: (sessionId, questionId, answer) =>
      Effect.promise(async () => {
        if (questionId === "stale-question") {
          throw new Error("No pending question: stale-question")
        }
        questionAnswers.push([sessionId, questionId, answer])
        await emit(sessionId, {
          kind: "session.output",
          subjectId: sessionId,
          payload: {
            outcome: answer.outcome,
            questionId,
            questions: [],
            sessionUpdate: "question_resolved"
          }
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
const runningServers: Array<RunningCodevisorServer> = []
const databases: Array<CodevisorDatabaseService> = []

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
  const dir = mkdtempSync(join(tmpdir(), "codevisor-server-"))
  tempDirs.push(dir)
  const db = await run(makeDatabase({ filename: join(dir, "codevisor.sqlite"), serverId }))
  databases.push(db)
  const spawner = makeSpawner()
  const agents = makeAgents()
  const mcp = makeMcpManager({ db, dataDir: dir })
  return {
    agents,
    services: {
      agents,
      db,
      mcp,
      terminal: makeTerminalManager({ defaultShell: "/bin/sh", env: {}, spawner })
    },
    spawner
  }
}

const start = async (auth = { allowLocalhostWithoutAuth: true, requireBearerToken: false }) => {
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

const startWithApp = async (
  services: CodevisorServerServices,
  fanout?: EventFanout
): Promise<RunningCodevisorServer> => {
  const appFanout = fanout ?? (await run(makeEventFanout))
  return await new Promise((resolve, reject) => {
    const app = makeCodevisorServerApp(
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

const readSseEvents = async (
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

const readWebSocketEvents = async (
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

describe("@codevisor/server", () => {
  it("bounds long-lived OAuth refresh timers to Node's supported range", () => {
    expect(boundedMcpTimerDelay(2_591_232_324)).toBe(2_147_000_000)
    expect(boundedMcpTimerDelay(3_480_000)).toBe(3_480_000)
  })

  it("gates HTTP and websocket clients until startup recovery finishes", async () => {
    const { services } = await makeServices("server-a")
    const reservation = createServer()
    await new Promise<void>((resolve) => reservation.listen(0, "127.0.0.1", resolve))
    const address = reservation.address()
    const port = typeof address === "object" && address !== null ? address.port : 0
    await new Promise<void>((resolve) => reservation.close(() => resolve()))

    let releaseRecovery: (() => void) | undefined
    const recoveryGate = new Promise<void>((resolve) => {
      releaseRecovery = resolve
    })
    const gatedServices: CodevisorServerServices = {
      ...services,
      db: {
        ...services.db,
        listSessions: Effect.promise(async () => {
          await recoveryGate
          return await run(services.db.listSessions)
        })
      }
    }
    const starting = run(
      startCodevisorServer(gatedServices, defaultServerConfig({ id: "server-a", port }))
    )

    let recoveryResponse: Response | undefined
    await waitFor(
      async () => {
        try {
          const response = await fetch(`http://127.0.0.1:${port}/v1/health`)
          if (response.status !== 503) return false
          recoveryResponse = response
          return true
        } catch {
          return false
        }
      },
      () => "for the recovery-gated listener"
    )
    expect(await recoveryResponse?.json()).toEqual({
      error: "Server recovery is still in progress"
    })

    await new Promise<void>((resolve) => {
      const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/events`)
      socket.once("error", () => resolve())
    })

    releaseRecovery?.()
    const server = await starting
    runningServers.push(server)
    expect(await (await fetch(`${server.url}/v1/health`)).json()).toMatchObject({ ok: true })
  })

  it("fails startup cleanly when orphan reconciliation cannot read sessions", async () => {
    const { services } = await makeServices("server-a")
    const failingServices: CodevisorServerServices = {
      ...services,
      db: {
        ...services.db,
        listSessions: Effect.sync(() => {
          throw new Error("recovery database unavailable")
        })
      }
    }

    await expect(
      run(startCodevisorServer(failingServices, defaultServerConfig({ id: "server-a", port: 0 })))
    ).rejects.toMatchObject({
      operation: "start",
      message: "recovery database unavailable"
    })
  })

  it("refuses to start when the port already has a listener", async () => {
    const { services } = await makeServices("server-a")
    const first = await run(
      startCodevisorServer(services, defaultServerConfig({ id: "server-a", port: 0 }))
    )
    runningServers.push(first)

    // The kernel happily grants a loopback bind that overlaps a wildcard one,
    // so a bind attempt alone would "succeed" and hijack the live server's
    // clients. The startup probe must reject before any bind happens.
    await expect(
      run(
        startCodevisorServer(services, defaultServerConfig({ id: "server-b", port: first.port }))
      )
    ).rejects.toMatchObject({
      operation: "start",
      message: expect.stringContaining("already has a listener")
    })
  })

  it("terminalizes orphaned durable state and restores the agent only when the chat connects", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-recovery-project-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-before-crash"
      })
    )
    await run(
      services.db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "orphaned-turn",
        turnState: "started"
      })
    )

    const backgroundOnly = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "background-only-agent"
      })
    )
    await run(
      services.db.appendEvent("session.updated", backgroundOnly.id, {
        backgroundTasks: [
          {
            id: "background-only-task",
            description: "Run detached work",
            status: "running",
            taskType: "shell"
          }
        ]
      })
    )
    const archived = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "archived-agent"
      })
    )
    await run(
      services.db.appendEvent("session.updated", archived.id, {
        initiatedBy: "user",
        turnId: "archived-turn",
        turnState: "started"
      })
    )
    await run(services.db.archiveSession(archived.id))
    // A concurrent-writer incident can strand a streaming row mid-transcript:
    // the conversation moved past it, so it is not the newest item and no
    // future terminal event can ever close it.
    const splitBrain = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "split-brain-agent"
      })
    )
    await run(
      services.db.appendConversationItem(
        splitBrain.id,
        "assistant",
        "stale-message",
        "half-finished answer",
        true
      )
    )
    await run(
      services.db.appendConversationItem(splitBrain.id, "user", "follow-up", "hello again", false)
    )
    await run(
      services.db.appendEvent("session.output", session.id, {
        sessionUpdate: "question",
        questionId: "orphaned-question",
        questions: [
          {
            id: "choice",
            question: "Continue?",
            options: [{ label: "Yes" }],
            allowsOther: false
          }
        ]
      })
    )
    await run(
      services.db.appendEvent("session.updated", session.id, {
        backgroundTasks: [
          {
            id: "orphaned-background-task",
            description: "Run checks",
            status: "running",
            taskType: "shell"
          }
        ]
      })
    )

    const server = await run(
      startCodevisorServer(services, defaultServerConfig({ id: "server-a", port: 0 }))
    )
    runningServers.push(server)

    // Startup recovery must stay database-only. A cold provider process can
    // take tens of seconds to initialize, and health/chat history do not need
    // it yet.
    expect(agents.loads).toEqual([])
    const page = await run(services.db.getTranscriptPage(session.id, undefined, 8))
    expect(page.pendingQuestion).toBeUndefined()
    expect(page.backgroundTasks).toEqual([])
    expect(
      (await run(services.db.getTranscriptPage(backgroundOnly.id, undefined, 8))).backgroundTasks
    ).toEqual([])
    // Archived sessions get no turn restoration, but their stale streaming
    // rows are still closed — unarchiving must not resurface an endless
    // in-progress turn.
    expect(
      (await run(services.db.getTranscriptPage(archived.id, undefined, 8))).items.at(-1)
    ).toMatchObject({
      isGenerating: false,
      stopReason: "interrupted",
      stopDetail: "The server restarted before this response finished."
    })
    const splitPage = await run(services.db.getTranscriptPage(splitBrain.id, undefined, 8))
    expect(splitPage.items.map((item) => item.isGenerating)).toEqual([false, false])
    expect(splitPage.items.at(0)).toMatchObject({
      role: "assistant",
      isGenerating: false,
      stopReason: "interrupted",
      stopDetail: "The server restarted before this response finished."
    })
    expect(page.items.at(-1)).toMatchObject({
      isGenerating: false,
      stopReason: "interrupted",
      stopDetail:
        "The server restarted before this turn finished. Reopen the chat to reconnect its agent session, then send a message to continue."
    })
    const events = await run(services.db.listSubjectEvents(session.id))
    expect(events.map((event) => event.payload)).toContainEqual(
      expect.objectContaining({
        outcome: "cancelled",
        questionId: "orphaned-question",
        sessionUpdate: "question_resolved"
      })
    )
    expect(events.map((event) => event.payload)).toContainEqual(
      expect.objectContaining({
        stopReason: "interrupted",
        turnId: "orphaned-turn",
        turnState: "ended"
      })
    )

    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).status
    ).toBe(200)
    expect(agents.loads).toEqual([["codex", "agent-before-crash", folder]])
  })

  it("persists session config and restores model before dependent reasoning and speed", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-session-config-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-session-config"
      })
    )
    const server = await startWithApp(services)
    runningServers.push(server)

    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).status
    ).toBe(200)
    for (const [configId, value] of [
      ["model", "model-saved"],
      ["reasoning", "high"],
      ["speed", "fast"],
      ["tone", "detailed"]
    ] as const) {
      expect(
        (
          await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
            body: JSON.stringify({ configId, value }),
            method: "POST"
          })
        ).status
      ).toBe(202)
    }
    expect(await run(services.db.getSessionConfigSelections(session.id))).toEqual({
      model: "model-saved",
      reasoning: "high",
      speed: "fast",
      tone: "detailed"
    })

    agents.configs.splice(0)
    const restored = (
      await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })
    ).body as { readonly configOptions: ReadonlyArray<SessionConfigOption> }
    expect(agents.configs).toEqual([
      [session.agentSessionId, "model", "model-saved"],
      [session.agentSessionId, "reasoning", "high"],
      [session.agentSessionId, "speed", "fast"],
      [session.agentSessionId, "tone", "detailed"]
    ])
    expect(configSelectionsFromTestOptions(restored.configOptions)).toEqual({
      model: "model-saved",
      reasoning: "high",
      speed: "fast",
      tone: "detailed"
    })

    await run(
      services.db.replaceSessionConfigSelections(session.id, {
        model: "model-removed",
        reasoning: "high",
        speed: "fast",
        tone: "tone-removed",
        "zzz-removed": "unavailable"
      })
    )
    agents.configs.splice(0)
    const fallback = (
      await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })
    ).body as { readonly configOptions: ReadonlyArray<SessionConfigOption> }
    expect(agents.configs).toEqual([])
    expect(configSelectionsFromTestOptions(fallback.configOptions)).toEqual({
      model: "model-default",
      reasoning: "low",
      speed: "standard",
      tone: "brief"
    })
    expect(await run(services.db.getSessionConfigSelections(session.id))).toEqual({
      model: "model-default",
      reasoning: "low",
      speed: "standard",
      tone: "brief"
    })
  })

  it("terminalizes a durably claimed prompt instead of losing or replaying it after restart", async () => {
    const { services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-claimed-prompt-project-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-before-prompt-crash"
      })
    )
    const queued = await run(services.db.createPromptQueueItem(session.id, "do not lose me"))
    expect(await run(services.db.claimPromptQueueItem(session.id))).toMatchObject({ id: queued.id })

    const completedSession = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-after-complete"
      })
    )
    const completed = await run(
      services.db.createPromptQueueItem(completedSession.id, "already finished")
    )
    await run(services.db.claimPromptQueueItem(completedSession.id))
    await run(
      services.db.appendEvent("session.output", completedSession.id, {
        role: "user",
        messageId: completed.id,
        text: completed.text
      })
    )
    await run(
      services.db.appendEvent("session.output", completedSession.id, {
        role: "assistant",
        text: "done"
      })
    )
    await run(
      services.db.appendEvent("session.updated", completedSession.id, {
        stopReason: "end_turn"
      })
    )

    const dispatchedSession = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-after-user-dispatch"
      })
    )
    const attachment = {
      fileId: "durable-file",
      name: "recovery.txt",
      mimeType: "text/plain",
      sizeBytes: 8,
      kind: "file" as const
    }
    const attachedMissingSession = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-before-attached-dispatch"
      })
    )
    await run(
      services.db.createPromptQueueItem(attachedMissingSession.id, "dispatch attachment", [
        attachment
      ])
    )
    await run(services.db.claimPromptQueueItem(attachedMissingSession.id))
    const dispatched = await run(
      services.db.createPromptQueueItem(dispatchedSession.id, "already dispatched", [attachment])
    )
    await run(services.db.claimPromptQueueItem(dispatchedSession.id))
    await run(
      services.db.appendEvent("session.output", dispatchedSession.id, {
        role: "user",
        messageId: dispatched.id,
        text: dispatched.text,
        attachments: [attachment]
      })
    )

    const server = await run(
      startCodevisorServer(services, defaultServerConfig({ id: "server-a", port: 0 }))
    )
    runningServers.push(server)

    const page = await run(services.db.getTranscriptPage(session.id, undefined, 8))
    expect(page.items).toMatchObject([
      { role: "user", text: "do not lose me", isGenerating: false },
      { role: "assistant", stopReason: "interrupted", isGenerating: false }
    ])
    expect(await run(services.db.listPromptQueue(session.id))).toEqual([])
    expect(await run(services.db.listProcessingPromptQueue(session.id))).toEqual([])

    const completedPage = await run(
      services.db.getTranscriptPage(completedSession.id, undefined, 8)
    )
    expect(completedPage.items).toMatchObject([
      { role: "user", text: "already finished" },
      { role: "assistant", text: "done", stopReason: "end_turn" }
    ])
    expect(await run(services.db.listProcessingPromptQueue(completedSession.id))).toEqual([])

    const dispatchedPage = await run(
      services.db.getTranscriptPage(dispatchedSession.id, undefined, 8)
    )
    expect(dispatchedPage.items).toMatchObject([
      { role: "user", text: "already dispatched", attachments: [attachment] },
      { role: "assistant", stopReason: "interrupted" }
    ])
    expect(await run(services.db.listProcessingPromptQueue(dispatchedSession.id))).toEqual([])
    expect(await run(services.db.listProcessingPromptQueue(attachedMissingSession.id))).toEqual([])

    const before = await run(services.db.listSubjectEvents(session.id))
    await reconcileOrphanedSessionTurns(services, await run(makeEventFanout), "server-a")
    expect(await run(services.db.listSubjectEvents(session.id))).toHaveLength(before.length)
  })

  it("terminalizes an orphaned turn even when its agent session cannot be restored yet", async () => {
    const { agents, services } = await makeServices("server-a")
    const missingFolder = join(tmpdir(), `codevisor-missing-${randomUUID()}`)
    const project = await run(services.db.createProject({ folderPath: missingFolder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "unrestorable-agent"
      })
    )
    await run(
      services.db.appendEvent("session.output", session.id, {
        role: "assistant",
        text: "partial answer"
      })
    )

    const server = await run(
      startCodevisorServer(services, defaultServerConfig({ id: "server-a", port: 0 }))
    )
    runningServers.push(server)

    expect(agents.loads).toEqual([])
    expect(await run(services.db.getTranscriptPage(session.id, undefined, 8))).toMatchObject({
      items: [
        {
          isGenerating: false,
          stopReason: "interrupted",
          stopDetail: expect.stringContaining("Reopen the chat to reconnect its agent session")
        }
      ]
    })
    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).status
    ).toBe(400)
    expect(agents.loads).toEqual([])
  })

  it("loads a large SSE tool catalog without opening the optional notification stream", async () => {
    const receivedHeaders: Array<string | undefined> = []
    const upstream = createServer(async (request, response) => {
      const workspace = request.headers["x-workspace"]
      receivedHeaders.push(Array.isArray(workspace) ? workspace.join(",") : workspace)
      if (request.method === "GET") {
        response.writeHead(500)
        response.end()
        return
      }
      const chunks: Buffer[] = []
      for await (const chunk of request) chunks.push(Buffer.from(chunk))
      const message = JSON.parse(Buffer.concat(chunks).toString("utf8")) as {
        id?: string | number
        method: string
      }
      if (message.method === "notifications/initialized") {
        response.writeHead(202)
        response.end()
        return
      }
      const result =
        message.method === "initialize"
          ? {
              protocolVersion: "2025-11-25",
              capabilities: { tools: { listChanged: true } },
              serverInfo: { name: "large-catalog", version: "1" }
            }
          : {
              tools: [
                {
                  name: "large_tool",
                  description: "x".repeat(30_000),
                  inputSchema: { type: "object" }
                }
              ]
            }
      response.writeHead(200, { "content-type": "text/event-stream" })
      response.end(
        `event: message\ndata: ${JSON.stringify({ jsonrpc: "2.0", id: message.id, result })}\n\n`
      )
    })
    await new Promise<void>((resolve) => upstream.listen(0, "127.0.0.1", resolve))
    const address = upstream.address()
    if (address === null || typeof address === "string") throw new Error("Missing upstream port")
    const transport = new NodeStreamableHttpTransport(
      new URL(`http://127.0.0.1:${address.port}/mcp`),
      undefined,
      { "X-Workspace": "emojis" }
    )
    const client = new McpClient({ name: "node-transport-test", version: "1" })
    try {
      await client.connect(transport)
      expect((await client.listTools()).tools).toHaveLength(1)
      expect(receivedHeaders).not.toContain(undefined)
      expect(receivedHeaders).toContain("emojis")
    } finally {
      await client.close()
      await new Promise<void>((resolve, reject) =>
        upstream.close((error) => (error === undefined ? resolve() : reject(error)))
      )
    }
  })

  it("serves the fixed session-scoped MCP gateway surface", async () => {
    const { server, services } = await start()
    await services.mcp.create({
      authType: "none",
      command: "codevisor-missing-posthog-mcp",
      name: "PostHog",
      transport: "stdio"
    })
    const firstGateway = await services.mcp.issueGateway("session-1")
    const gateway = await services.mcp.issueGateway("session-1")
    const otherSessionGateway = await services.mcp.issueGateway("session-2")
    expect(gateway).toEqual(firstGateway)
    expect(otherSessionGateway.bearerToken).toBe(gateway.bearerToken)
    expect(otherSessionGateway.url).not.toBe(gateway.url)
    const client = new McpClient({ name: "gateway-test", version: "1" })
    await client.connect(
      new StreamableHTTPClientTransport(new URL(gateway.url), {
        requestInit: { headers: { Authorization: `Bearer ${gateway.bearerToken}` } }
      }) as unknown as McpTransport
    )
    const listed = await client.listTools()
    expect(listed.tools.map((tool) => tool.name)).toEqual([
      "search",
      "describe",
      "execute",
      "run_code"
    ])
    expect(listed.tools.find((tool) => tool.name === "search")?.description).toContain("PostHog")
    expect(listed.tools.find((tool) => tool.name === "run_code")?.description).toContain("PostHog")
    let toolListChanges = 0
    client.setNotificationHandler(ToolListChangedNotificationSchema, () => {
      toolListChanges += 1
    })
    await services.mcp.create({
      authType: "none",
      command: "codevisor-missing-linear-mcp",
      name: "Linear",
      transport: "stdio"
    })
    await waitFor(() => toolListChanges > 0)
    expect(
      (await client.listTools()).tools.find((tool) => tool.name === "search")?.description
    ).toContain("Linear")
    const executed = await client.callTool({
      name: "run_code",
      arguments: { code: "async () => 6 * 7" }
    })
    expect(executed.isError).not.toBe(true)
    expect(JSON.stringify(executed.content)).toContain("42")
    const searchedInCode = await client.callTool({
      name: "run_code",
      arguments: { code: 'async () => await tools.search({ query: "missing" })' }
    })
    expect(searchedInCode.isError).not.toBe(true)
    expect(JSON.stringify(searchedInCode.content)).toContain('\\"total\\":0')
    await client.close()

    const unauthorized = await fetch(`${server.url}/mcp/gateway`, { method: "POST" })
    expect(unauthorized.status).toBe(401)
  })

  it("detects MCP authorization challenges", async () => {
    const detector = createServer((request, response) => {
      if (request.url === "/oauth") {
        response.writeHead(401, {
          "www-authenticate": 'Bearer resource_metadata="https://auth.example.test/resource"'
        })
      } else if (request.url === "/bearer") {
        response.writeHead(401, { "www-authenticate": "Bearer" })
      } else if (request.url === "/metadata") {
        response.writeHead(401)
      } else if (request.url === "/required") {
        response.writeHead(401)
      } else if (request.url === "/.well-known/oauth-protected-resource/metadata") {
        response.writeHead(200, { "content-type": "application/json" })
        response.end(
          JSON.stringify({
            authorization_servers: ["https://auth.example.test"],
            resource: `http://${request.headers.host}/metadata`
          })
        )
        return
      } else if (request.url?.startsWith("/.well-known/")) {
        response.writeHead(404)
      } else {
        response.writeHead(200, { "content-type": "application/json" })
      }
      response.end("{}")
    })
    await new Promise<void>((resolve) => detector.listen(0, "127.0.0.1", resolve))
    const address = detector.address()
    if (address === null || typeof address === "string") throw new Error("Missing detector port")
    const { server } = await start()
    try {
      for (const [path, authType] of [
        ["none", "none"],
        ["bearer", "bearer"],
        ["metadata", "oauth"],
        ["required", "bearer"],
        ["oauth", "oauth"]
      ] as const) {
        const detected = await jsonRequest(server, "/v1/mcps/detect-auth", {
          method: "POST",
          body: JSON.stringify({ url: `http://127.0.0.1:${address.port}/${path}` })
        })
        expect(detected.status).toBe(200)
        expect(detected.body).toMatchObject({ authType })
      }
      const created = await jsonRequest(server, "/v1/mcps", {
        method: "POST",
        body: JSON.stringify({
          enabled: false,
          name: "Auto OAuth",
          transport: "http",
          url: `http://127.0.0.1:${address.port}/oauth`
        })
      })
      expect(created.status).toBe(201)
      expect(created.body).toMatchObject({
        authType: "oauth",
        connectionState: "needsAuthorization",
        enabled: false
      })
    } finally {
      await new Promise<void>((resolve, reject) =>
        detector.close((error) => (error === undefined ? resolve() : reject(error)))
      )
    }
  })

  it("manages MCP installations without returning encrypted credentials", async () => {
    const { server, services } = await start()
    const created = await jsonRequest(server, "/v1/mcps", {
      method: "POST",
      body: JSON.stringify({
        authType: "bearer",
        bearerToken: "secret-token",
        headers: { "X-Workspace": "emojis", Authorization: "secret-header" },
        enabled: false,
        name: "Example",
        transport: "http",
        url: "https://example.test/mcp"
      })
    })
    expect(created.status).toBe(201)
    expect(created.body).toMatchObject({
      authType: "bearer",
      enabled: false,
      name: "Example"
    })
    expect(JSON.stringify(created.body)).not.toContain("secret-token")
    expect(created.body).toMatchObject({ headerNames: ["Authorization", "X-Workspace"] })
    expect(JSON.stringify(created.body)).not.toContain("secret-header")
    expect(JSON.stringify(created.body)).not.toContain("secretCipher")

    const id = (created.body as { id: string }).id
    const updated = await jsonRequest(server, `/v1/mcps/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ name: "Renamed" })
    })
    expect(updated.status).toBe(200)
    expect(updated.body).toMatchObject({ enabled: false, name: "Renamed" })

    const listed = await jsonRequest(server, "/v1/mcps")
    expect(listed.body).toEqual([expect.objectContaining({ id, name: "Renamed" })])

    expect((await jsonRequest(server, `/v1/mcps/${id}`, { method: "DELETE" })).status).toBe(204)

    const local = await jsonRequest(server, "/v1/mcps", {
      method: "POST",
      body: JSON.stringify({
        authType: "none",
        command: "missing-local-mcp",
        enabled: false,
        env: { API_KEY: "local-secret", REGION: "us-west" },
        name: "Local",
        transport: "stdio"
      })
    })
    expect(local.status).toBe(201)
    expect(local.body).toMatchObject({ environmentNames: ["API_KEY", "REGION"] })
    expect(JSON.stringify(local.body)).not.toContain("local-secret")
    const localId = (local.body as { id: string }).id
    const changedLocal = await jsonRequest(server, `/v1/mcps/${localId}`, {
      method: "PATCH",
      body: JSON.stringify({ env: { ACCOUNT: "new-secret" }, removeEnv: ["REGION"] })
    })
    expect(changedLocal.body).toMatchObject({ environmentNames: ["ACCOUNT", "API_KEY"] })
    expect(JSON.stringify(changedLocal.body)).not.toContain("new-secret")

    const project = await run(services.db.createProject({ folderPath: "/tmp/mcp-route-scope" }))
    const session = await run(
      services.db.createSession({ harnessId: "codex", projectId: project.id, title: "Scoped" })
    )
    expect(
      (
        await jsonRequest(server, `/v1/projects/${project.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({ enabled: false })
        })
      ).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({ enabled: false })
        })
      ).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(server, `/v1/projects/${project.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({})
        })
      ).status
    ).toBe(400)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({})
        })
      ).status
    ).toBe(400)

    const publicLocal = local.body as McpServer
    vi.spyOn(services.mcp, "connect").mockResolvedValue(publicLocal)
    vi.spyOn(services.mcp, "tools").mockResolvedValue([])
    vi.spyOn(services.mcp, "beginOAuth").mockResolvedValue("https://example.test/authorize")
    vi.spyOn(services.mcp, "disconnectOAuth").mockResolvedValue(publicLocal)
    const finishOAuth = vi.spyOn(services.mcp, "finishOAuth").mockResolvedValue(publicLocal)
    expect((await jsonRequest(server, `/v1/mcps/${localId}/tools`)).status).toBe(200)
    expect(
      (await jsonRequest(server, `/v1/mcps/${localId}/connect`, { method: "POST" })).status
    ).toBe(200)
    expect(
      (await jsonRequest(server, `/v1/mcps/${localId}/oauth-start`, { method: "POST" })).status
    ).toBe(201)
    expect(
      (await jsonRequest(server, `/v1/mcps/${localId}/oauth-disconnect`, { method: "POST" })).status
    ).toBe(200)
    expect(
      (await jsonRequest(server, `/v1/mcps/${localId}/unknown`, { method: "POST" })).status
    ).toBe(404)
    expect((await jsonRequest(server, "/v1/mcps", { method: "PUT" })).status).toBe(404)
    expect((await jsonRequest(server, `/v1/mcps/${localId}`)).status).toBe(404)
    expect(
      await fetch(`${server.url}/v1/mcps/oauth/callback?state=state-1&code=code-1`).then(
        (response) => response.status
      )
    ).toBe(200)
    expect(finishOAuth).toHaveBeenCalledWith("state-1", "code-1")
    expect(
      await fetch(`${server.url}/v1/mcps/oauth/callback?state=state-1`).then(
        (response) => response.status
      )
    ).toBe(400)
    expect(
      await fetch(`${server.url}/v1/mcps/oauth/complete`).then((response) => response.status)
    ).toBe(200)

    expect((await jsonRequest(server, `/v1/mcps/${localId}`, { method: "DELETE" })).status).toBe(
      204
    )
    expect((await jsonRequest(server, "/v1/mcps")).body).toEqual([])

    const { mcp: _mcp, ...withoutMcp } = services
    const unavailable = await startWithApp(withoutMcp)
    runningServers.push(unavailable)
    expect((await jsonRequest(unavailable, "/v1/mcps")).status).toBe(501)
    expect(
      (
        await jsonRequest(unavailable, `/v1/projects/${project.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({ enabled: true })
        })
      ).status
    ).toBe(501)
    expect(
      (
        await jsonRequest(unavailable, `/v1/sessions/${session.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({ enabled: true })
        })
      ).status
    ).toBe(501)
    expect(
      await fetch(`${unavailable.url}/mcp/gateway`, { method: "POST" }).then((r) => r.status)
    ).toBe(501)
    expect(
      await fetch(`${unavailable.url}/v1/mcps/oauth/callback?state=x&code=y`).then(
        (response) => response.status
      )
    ).toBe(501)
  })

  it("exposes harness authentication and account management routes", async () => {
    const { services, agents } = await makeServices("server-a")
    const legacyServer = await startWithApp(services)
    runningServers.push(legacyServer)
    const unavailableRequests: ReadonlyArray<readonly [string, string]> = [
      ["GET", "/v1/harnesses/pi/providers"],
      ["POST", "/v1/harnesses/pi/providers/openai/login"],
      ["DELETE", "/v1/harnesses/pi/providers/openai"],
      ["POST", "/v1/harnesses/pi/auth-flows/pi-flow-1/answer"],
      ["GET", "/v1/harnesses/pi/auth-flows/pi-flow-1"],
      ["DELETE", "/v1/harnesses/pi/auth-flows/pi-flow-1"],
      ["POST", "/v1/harnesses/auth/refresh"],
      ["DELETE", "/v1/harnesses/codex/accounts/account-1/login/flow-1"],
      ["POST", "/v1/harnesses/codex/accounts/account-1/login"],
      ["POST", "/v1/harnesses/codex/accounts/account-1/auth/probe"],
      ["PATCH", "/v1/harnesses/codex/accounts/account-1"],
      ["GET", "/v1/harnesses/codex/accounts"],
      ["GET", "/v1/harnesses/opencode/accounts/account-1/providers"],
      ["POST", "/v1/harnesses/opencode/accounts/account-1/providers/openai/login"],
      ["DELETE", "/v1/harnesses/opencode/accounts/account-1/providers/openai"],
      ["GET", "/v1/harnesses/opencode/auth-flows/flow-open"],
      ["DELETE", "/v1/harnesses/opencode/auth-flows/flow-open"],
      ["POST", "/v1/harnesses/opencode/auth-flows/flow-open/answer"]
    ]
    for (const [method, path] of unavailableRequests) {
      expect(
        (
          await jsonRequest(legacyServer, path, {
            method,
            ...(method === "PATCH" || method === "POST" ? { body: JSON.stringify({}) } : {})
          })
        ).status
      ).toBe(501)
    }

    const account = {
      id: "account-1",
      harnessId: "codex",
      profileKind: "default" as const,
      label: "person@example.com",
      email: "person@example.com",
      authState: "authenticated" as const,
      isActive: true,
      canLogin: true,
      canLogout: true
    }
    const accountList = [account]
    const piProvider = { id: "openai", name: "OpenAI", methods: ["api_key" as const] }
    const piFlow = {
      id: "pi-flow-1",
      providerId: piProvider.id,
      state: "waiting" as const,
      prompt: {
        id: "api-key",
        type: "secret" as const,
        message: "Enter OpenAI API key",
        options: []
      }
    }
    let authState: "authenticated" | "unauthenticated" = "authenticated"
    let activeContextAvailable = true
    const auth: HarnessAuthManager = {
      decorateHarnesses: async (values) =>
        values.map((harness) => ({
          ...harness,
          desiredEnabled: harness.enabled,
          auth: {
            state: authState,
            activeAccountId: account.id,
            accounts: accountList,
            loginMethods: [{ id: "browser", name: "Browser", kind: "browser" }],
            supportsMultipleAccounts: true
          }
        })),
      refresh: vi.fn(async () => undefined),
      accounts: vi.fn(async () => accountList),
      createAccount: vi.fn(async () => account),
      renameAccount: vi.fn(async () => account),
      removeAccount: vi.fn(async () => undefined),
      activateAccount: vi.fn(async () => undefined),
      probeAccount: vi.fn(async () => account),
      beginLogin: vi.fn(async () => ({
        id: "flow-1",
        accountId: account.id,
        kind: "complete" as const
      })),
      cancelLogin: vi.fn(async () => undefined),
      logout: vi.fn(async () => ({ ...account, authState: "unauthenticated" as const })),
      accountContext: vi.fn(async () => ({ id: account.id, profileKind: "default" as const })),
      activeAccountContext: vi.fn(async () =>
        activeContextAvailable ? { id: account.id, profileKind: "default" as const } : undefined
      ),
      markAccountExpired: vi.fn(async () => undefined),
      piProviders: vi.fn(async () => [piProvider]),
      beginPiLogin: vi.fn(async () => piFlow),
      piLoginFlow: vi.fn(() => piFlow),
      answerPiLogin: vi.fn(async () => ({ ...piFlow, state: "complete" as const })),
      cancelPiLogin: vi.fn(() => undefined),
      logoutPiProvider: vi.fn(async () => undefined),
      openCodeProviders: vi.fn(async () => [
        {
          id: "openai",
          name: "OpenAI",
          methods: [{ id: "0", type: "oauth" as const, label: "ChatGPT", prompts: [] }],
          credentialType: "oauth" as const
        }
      ]),
      beginOpenCodeLogin: vi.fn(async () => ({
        id: "flow-open",
        accountId: account.id,
        providerId: "openai",
        state: "waiting" as const,
        authorization: {
          url: "https://example.test/login",
          method: "code" as const,
          instructions: "Sign in"
        }
      })),
      openCodeLoginFlow: vi.fn(() => ({
        id: "flow-open",
        accountId: account.id,
        providerId: "openai",
        state: "waiting" as const
      })),
      answerOpenCodeLogin: vi.fn(async () => ({
        id: "flow-open",
        accountId: account.id,
        providerId: "openai",
        state: "complete" as const
      })),
      cancelOpenCodeLogin: vi.fn(() => undefined),
      logoutOpenCodeProvider: vi.fn(async () => undefined),
      subscribe: () => () => undefined
    }
    const server = await startWithApp({ ...services, auth })
    runningServers.push(server)

    expect((await jsonRequest(server, "/v1/harnesses")).status).toBe(200)
    expect((await jsonRequest(server, "/v1/harnesses/pi/providers")).body).toEqual([piProvider])
    expect(
      await jsonRequest(server, "/v1/harnesses/pi/providers/openai/login", {
        method: "POST",
        body: JSON.stringify({ method: "api_key" })
      })
    ).toMatchObject({ status: 201, body: piFlow })
    expect(auth.beginPiLogin).toHaveBeenCalledWith("openai", "api_key")
    expect(
      await jsonRequest(server, "/v1/harnesses/pi/auth-flows/pi-flow-1/answer", {
        method: "POST",
        body: JSON.stringify({ value: "sk-test" })
      })
    ).toMatchObject({ status: 200, body: { state: "complete" } })
    expect(auth.answerPiLogin).toHaveBeenCalledWith("pi-flow-1", "sk-test")
    expect((await jsonRequest(server, "/v1/harnesses/pi/auth-flows/pi-flow-1")).body).toEqual(
      piFlow
    )
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/pi/auth-flows/pi-flow-1", {
          method: "DELETE"
        })
      ).status
    ).toBe(204)
    expect(auth.cancelPiLogin).toHaveBeenCalledWith("pi-flow-1")
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/pi/providers/openai", {
          method: "DELETE"
        })
      ).status
    ).toBe(204)
    expect(auth.logoutPiProvider).toHaveBeenCalledWith("openai")
    for (const [method, path] of [
      ["GET", "/v1/harnesses/pi/providers/openai/login"],
      ["GET", "/v1/harnesses/pi/providers/openai"],
      ["GET", "/v1/harnesses/pi/auth-flows/pi-flow-1/answer"],
      ["POST", "/v1/harnesses/pi/auth-flows/pi-flow-1"],
      ["POST", "/v1/harnesses/opencode/auth-flows/flow-open"]
    ] as const) {
      expect((await jsonRequest(server, path, { method })).status).toBe(404)
    }
    expect(
      (await jsonRequest(server, "/v1/harnesses/auth/refresh", { method: "POST" })).status
    ).toBe(200)
    const targetedRefresh = await jsonRequest(
      server,
      "/v1/harnesses/auth/refresh?harnessId=codex",
      { method: "POST" }
    )
    expect(targetedRefresh).toMatchObject({
      status: 200,
      body: [{ id: "codex" }]
    })
    expect(auth.refresh).toHaveBeenLastCalledWith("codex")
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1", {
          method: "PATCH",
          body: JSON.stringify({})
        })
      ).status
    ).toBe(400)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1/unknown", {
          method: "POST",
          body: JSON.stringify({})
        })
      ).status
    ).toBe(404)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1", {
          method: "GET"
        })
      ).status
    ).toBe(404)
    expect((await jsonRequest(server, "/v1/harnesses/codex/accounts")).body).toEqual(accountList)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts", {
          method: "POST",
          body: JSON.stringify({ label: "Work" })
        })
      ).status
    ).toBe(201)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts", {
          method: "PUT",
          body: JSON.stringify({})
        })
      ).status
    ).toBe(404)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1", {
          method: "PATCH",
          body: JSON.stringify({ label: "Renamed" })
        })
      ).status
    ).toBe(200)
    authState = "unauthenticated"
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex", {
          method: "PATCH",
          body: JSON.stringify({ enabled: true })
        })
      ).status
    ).toBe(409)
    authState = "authenticated"
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1/auth/probe", {
          method: "POST"
        })
      ).status
    ).toBe(200)
    for (const action of ["activate", "login", "logout"]) {
      expect(
        (
          await jsonRequest(server, `/v1/harnesses/codex/accounts/account-1/${action}`, {
            method: "POST",
            body: JSON.stringify(
              action === "login" ? { methodId: "apiKey", apiKey: "sk-test-secret" } : {}
            )
          })
        ).status
      ).toBe(action === "login" ? 201 : 200)
    }
    expect(auth.beginLogin).toHaveBeenCalledWith("account-1", "apiKey", "sk-test-secret")
    expect(
      (await jsonRequest(server, "/v1/harnesses/opencode/accounts/account-1/providers")).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(
          server,
          "/v1/harnesses/opencode/accounts/account-1/providers/openai/login",
          {
            method: "POST",
            body: JSON.stringify({
              methodId: "0",
              inputs: { plan: "plus" }
            })
          }
        )
      ).status
    ).toBe(201)
    expect(auth.beginOpenCodeLogin).toHaveBeenCalledWith(
      "account-1",
      "openai",
      "0",
      { plan: "plus" },
      undefined
    )
    expect((await jsonRequest(server, "/v1/harnesses/opencode/auth-flows/flow-open")).status).toBe(
      200
    )
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/opencode/auth-flows/flow-open/answer", {
          method: "POST",
          body: JSON.stringify({ code: "authorization-code" })
        })
      ).status
    ).toBe(200)
    expect(auth.answerOpenCodeLogin).toHaveBeenCalledWith("flow-open", "authorization-code")
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/opencode/accounts/account-1/providers/openai", {
          method: "DELETE"
        })
      ).status
    ).toBe(204)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/opencode/auth-flows/flow-open", {
          method: "DELETE"
        })
      ).status
    ).toBe(204)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1/login/flow-1", {
          method: "DELETE"
        })
      ).status
    ).toBe(204)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex", {
          method: "PATCH",
          body: JSON.stringify({ enabled: true })
        })
      ).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1", {
          method: "DELETE"
        })
      ).status
    ).toBe(204)

    const projectFolder = mkdtempSync(join(tmpdir(), "codevisor-auth-project-"))
    tempDirs.push(projectFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        method: "POST",
        body: JSON.stringify({ folderPath: projectFolder })
      })
    ).body as { id: string }
    await run(
      services.db.saveHarnessAccount({
        id: account.id,
        harnessId: account.harnessId,
        profileKind: account.profileKind,
        label: account.label,
        email: account.email,
        authState: account.authState,
        canLogin: account.canLogin,
        canLogout: account.canLogout
      })
    )
    const createdResponse = await jsonRequest(server, "/v1/sessions", {
      method: "POST",
      body: JSON.stringify({ projectId: project.id, harnessId: "codex" })
    })
    expect(createdResponse.status).toBe(201)
    const created = createdResponse.body as {
      id: string
      agentSessionId: string
      harnessAccountId: string
    }
    expect(created.harnessAccountId).toBe(account.id)
    await agents.emit(created.agentSessionId, {
      kind: "session.authRequired",
      subjectId: created.agentSessionId,
      payload: { detail: "Please sign in again" }
    })
    await agents.emit(created.agentSessionId, {
      kind: "session.authRequired",
      subjectId: created.agentSessionId,
      payload: null
    })
    await waitFor(() => vi.mocked(auth.markAccountExpired).mock.calls.length === 2)
    await jsonRequest(server, `/v1/sessions/${created.id}/prompt`, {
      method: "POST",
      body: JSON.stringify({ text: "token expired" })
    })
    await waitFor(() => vi.mocked(auth.markAccountExpired).mock.calls.length === 3)
    await waitFor(async () =>
      (await run(services.db.listSubjectEvents(created.id))).some(
        (event) => event.kind === "session.error"
      )
    )

    const explicitAccountSession = await jsonRequest(server, "/v1/sessions", {
      method: "POST",
      body: JSON.stringify({
        projectId: project.id,
        harnessId: "codex",
        harnessAccountId: account.id,
        deferAgentSession: true
      })
    })
    expect(explicitAccountSession.status).toBe(201)

    activeContextAvailable = false
    expect(
      (
        await jsonRequest(server, "/v1/sessions", {
          method: "POST",
          body: JSON.stringify({ projectId: project.id, harnessId: "codex" })
        })
      ).status
    ).toBe(409)

    activeContextAvailable = true
    const legacy = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: ""
      })
    )
    await jsonRequest(server, `/v1/sessions/${legacy.id}/prompt`, {
      method: "POST",
      body: JSON.stringify({ text: "hello" })
    })
    await waitFor(
      async () =>
        (await run(services.db.getSessionSummary(legacy.id))).harnessAccountId === account.id
    )
    await waitFor(async () => (await run(services.db.listPromptQueue(legacy.id))).length === 0)
    await waitFor(async () =>
      (await run(services.db.listSubjectEvents(legacy.id))).some(
        (event) =>
          event.kind === "session.updated" &&
          typeof event.payload === "object" &&
          event.payload !== null &&
          "turnState" in event.payload &&
          event.payload.turnState === "ended"
      )
    )

    activeContextAvailable = false
    const blocked = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex", agentSessionId: "" })
    )
    await jsonRequest(server, `/v1/sessions/${blocked.id}/prompt`, {
      method: "POST",
      body: JSON.stringify({ text: "blocked" })
    })
    await waitFor(async () =>
      (await run(services.db.listSubjectEvents(blocked.id))).some(
        (event) => event.kind === "session.error"
      )
    )
  })

  it("serves health, info, OpenAPI, update state, pairing, and auth", async () => {
    const { server, services } = await start()

    expect((await jsonRequest(server, "/v1/health")).body).toMatchObject({
      database: "ready",
      ok: true
    })
    expect((await jsonRequest(server, "/v1/info")).body).toMatchObject({
      id: "server-a",
      kind: "local",
      machineId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      arch: process.arch,
      hostname: expect.any(String)
    })
    const discovery = await jsonRequest(server, "/v1/discovery")
    expect(discovery.body).toMatchObject({
      serverId: "server-a",
      machineId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      kind: "local",
      platform: process.platform,
      hostname: expect.any(String)
    })
    // The machine identity is stable across requests.
    expect((await jsonRequest(server, "/v1/discovery")).body).toMatchObject({
      machineId: (discovery.body as { machineId: string }).machineId
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
      name: "Local Codevisor",
      port: 49361,
      version: "0.1.0"
    })
    expect(
      (await jsonRequest(server, "/v1/auth/pairing-token", { method: "POST" })).body
    ).toMatchObject({
      token: expect.stringMatching(/^hm_/)
    })

    // The connection token is stable across calls, and rotation replaces it.
    const firstConnection = await jsonRequest(server, "/v1/auth/connection-token")
    expect(firstConnection.status).toBe(200)
    const connectionToken = (firstConnection.body as { token: string }).token
    expect(connectionToken).toMatch(/^hm_/)
    expect(
      ((await jsonRequest(server, "/v1/auth/connection-token")).body as { token: string }).token
    ).toBe(connectionToken)
    const rotation = await jsonRequest(server, "/v1/auth/connection-token/rotate", {
      method: "POST"
    })
    expect(rotation.status).toBe(201)
    expect((rotation.body as { token: string }).token).not.toBe(connectionToken)

    expect(defaultDatabasePath()).toContain("codevisor-server.sqlite")

    // Shutdown is acknowledged even when the host process installed no handler.
    expect((await jsonRequest(server, "/v1/shutdown", { method: "POST" })).status).toBe(202)

    // Servers without an updater refuse remote update requests.
    expect((await jsonRequest(server, "/v1/update/apply", { method: "POST" })).status).toBe(409)

    let shutdownRequests = 0
    const stoppable = await run(
      startCodevisorServer(
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
      startCodevisorServer(
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
      startCodevisorServer(
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
    // Discovery stays reachable without a token so peers can be found.
    expect((await jsonRequest(secured, "/v1/discovery")).status).toBe(200)
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
      startCodevisorServer(
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

  it("refuses to apply an update while a chat is mid-turn", async () => {
    const { agents, services } = await makeServices("server-busy")
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({
          id: "server-busy",
          port: 0,
          updater: {
            apply: async () => undefined,
            check: async () => ({
              channel: "stable",
              checkedAt: "2026-06-30T00:00:00.000Z",
              currentVersion: "0.1.0",
              latestVersion: "0.2.0",
              migrationState: "idle" as const,
              updateAvailable: true
            })
          }
        })
      )
    )
    runningServers.push(server)

    const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-busy-"))
    tempDirs.push(workspaceRoot)
    const workspaceFolder = join(workspaceRoot, "codevisor")
    mkdirSync(workspaceFolder)
    const workspace = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: workspaceFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: workspace.id, harnessId: "codex", title: "Busy" }),
        method: "POST"
      })
    ).body as { readonly id: string }

    // "slow prompt" keeps the session in activePromptSessions for ~250ms; the
    // update must be refused for that whole window.
    await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ text: "slow prompt" }),
      method: "POST"
    })
    await waitFor(() => agents.prompts.length === 1)

    const busy = await jsonRequest(server, "/v1/update/apply", { method: "POST" })
    expect(busy.status).toBe(200)
    expect(busy.body).toMatchObject({ accepted: false, reason: "busy" })

    // Once the turn finishes the update goes through again.
    await waitFor(async () => {
      const applied = await jsonRequest(server, "/v1/update/apply", { method: "POST" })
      return applied.status === 202
    })
  })

  it("adopts a client-supplied messageId as the queue item and echo id", async () => {
    const { services } = await makeServices("server-prompt-message-id")
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ id: "server-prompt-message-id", port: 0 })
      )
    )
    runningServers.push(server)
    const folder = join(mkdtempSync(join(tmpdir(), "codevisor-prompt-id-")), "repo")
    mkdirSync(folder, { recursive: true })
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: folder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: project.id, harnessId: "codex", title: "Identity" }),
        method: "POST"
      })
    ).body as { readonly id: string }

    const messageId = "0f6b2c8e-8a34-4b9d-9f2e-1a7c5d3e9b01"
    const accepted = await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ text: "run pwd", messageId }),
      method: "POST"
    })
    expect(accepted.status).toBe(202)
    expect((accepted.body as { queueItemId?: string }).queueItemId).toBe(messageId)

    // The user echo event carries the client's id back, so clients can
    // reconcile their optimistic message by identity.
    await waitFor(async () =>
      (await run(services.db.listSubjectEvents(session.id))).some(
        (event) =>
          event.kind === "session.output" &&
          (event.payload as { messageId?: string }).messageId === messageId &&
          (event.payload as { role?: string }).role === "user"
      )
    )
  })

  it("applies the CORS allowlist to browser origins", async () => {
    const { services } = await makeServices("server-cors")
    const server = await run(
      startCodevisorServer(
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
      startCodevisorServer(plainServices, defaultServerConfig({ id: "server-no-cors", port: 0 }))
    )
    runningServers.push(plain)
    const noCors = await fetch(`${plain.url}/v1/health`, {
      headers: { Origin: "tauri://localhost" }
    })
    expect(noCors.headers.get("access-control-allow-origin")).toBeNull()
  })

  it("manages workspaces, harnesses, sessions, actions, and event replay", async () => {
    const { agents, server, services } = await start()
    const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-workspace-"))
    tempDirs.push(workspaceRoot)
    const workspaceFolder = join(workspaceRoot, "codevisor")
    const noModesFolder = join(workspaceRoot, "no-modes")
    const capabilityFailFolder = join(workspaceRoot, "capability-fail")
    const cwdFile = join(workspaceRoot, "cwd-file")
    mkdirSync(workspaceFolder)
    mkdirSync(noModesFolder)
    mkdirSync(capabilityFailFolder)
    writeFileSync(cwdFile, "")
    const legacyRoot = mkdtempSync(join(tmpdir(), "codevisor-server-legacy-"))
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
      { id: "codex", enabled: true, installHint: "npm install -g @openai/codex" }
    ])

    // Rescan re-resolves the runtime environment, then returns the fresh list.
    const rescanResponse = await jsonRequest(server, "/v1/harnesses/rescan", { method: "POST" })
    expect(rescanResponse.status).toBe(200)
    expect(rescanResponse.body).toMatchObject([{ id: "codex", enabled: true }])
    expect(agents.environmentRefreshes).toHaveLength(1)

    // Native agent sessions come from the harness's own store via the runtime.
    expect((await jsonRequest(server, "/v1/harnesses/codex/agent-sessions")).body).toEqual([
      { sessionId: "native-1", cwd: "/repo/native", title: "Old codex chat" }
    ])
    expect((await jsonRequest(server, "/v1/harnesses/gemini/agent-sessions")).body).toEqual([])
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
          ],
          supportsGoals: true
        }
      ]
    })
    expect(agents.inspections).toEqual([["codex", workspaceFolder]])
    expect((await jsonRequest(server, "/v1/capabilities")).body).toMatchObject({
      harnesses: [{ harness: { id: "codex" } }]
    })
    const missingCwdCapabilities = await jsonRequest(
      server,
      "/v1/capabilities?cwd=%2Ftmp%2Fmissing-codevisor-workspace"
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
    expect(session.agentSessionId).toBe("agent-codex-codevisor")
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: { sessionUpdate: "session_info_update", title: "  Harness-generated title  " }
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { title: "Harness-generated title" }
    })
    // Repeating the current harness title is an idempotent no-op.
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: {
        sessionUpdate: "session_info_update",
        title: "Harness-generated title"
      }
    })
    // A missing/blank harness title keeps the existing first-prompt fallback.
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: { sessionUpdate: "session_info_update", title: "   " }
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { title: "Harness-generated title" }
    })
    await jsonRequest(server, `/v1/sessions/${session.id}`, {
      body: JSON.stringify({ title: "User-provided title" }),
      method: "PATCH"
    })
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: {
        sessionUpdate: "session_info_update",
        title: "Later harness-generated title"
      }
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { title: "User-provided title" }
    })
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
    ).toMatchObject({ agentSessionId: "agent-codex-codevisor", id: session.id })

    const deferredResponse = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        projectId: workspace.id,
        harnessId: "codex",
        title: "Deferred chat",
        deferAgentSession: true
      }),
      method: "POST"
    })
    const deferred = deferredResponse.body as {
      readonly id: string
      readonly agentSessionId?: string
    }
    expect(deferred.agentSessionId).toBe("")
    expect(agents.creations).toEqual([["codex", workspaceFolder]])
    await jsonRequest(server, `/v1/sessions/${deferred.id}/prompt`, {
      body: JSON.stringify({ text: "hello deferred" }),
      method: "POST"
    })
    await waitFor(() => agents.prompts.some((prompt) => prompt[1] === "hello deferred"))
    const deferredDetail = (await jsonRequest(server, `/v1/sessions/${deferred.id}`)).body as {
      readonly session: { readonly agentSessionId?: string }
    }
    expect(deferredDetail.session.agentSessionId).toBe("agent-codex-codevisor")
    expect(agents.prompts).toContainEqual(["agent-codex-codevisor", "hello deferred"])

    const concurrentSessionBody = JSON.stringify({
      id: "client-session-concurrent",
      projectId: workspace.id,
      harnessId: "codex",
      title: "Concurrent chat"
    })
    const workspaceCreationsBeforeConcurrent = agents.creations.filter(
      (creation) => creation[1] === workspaceFolder
    ).length
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
      agentSessionId: "agent-codex-codevisor",
      id: "client-session-concurrent"
    })
    expect(secondConcurrent.body).toEqual(firstConcurrent.body)
    expect(agents.creations.filter((creation) => creation[1] === workspaceFolder)).toHaveLength(
      workspaceCreationsBeforeConcurrent + 1
    )

    expect(await jsonRequest(server, "/v1/sessions")).toMatchObject({
      body: expect.arrayContaining([expect.objectContaining({ id: session.id })])
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { id: session.id }
    })
    expect(await jsonRequest(server, `/v1/sessions/${session.id}/branch-diff`)).toEqual({
      body: null,
      status: 200
    })
    expect((await jsonRequest(server, "/v1/sessions/missing/branch-diff")).status).toBe(404)
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
        folderPath: "/tmp/codevisor-missing-session-workspace",
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
      body: { error: "Project folder does not exist: /tmp/codevisor-missing-session-workspace" },
      status: 400
    })
    expect((await jsonRequest(server, "/v1/sessions/missing")).status).toBe(500)

    const promptCountBeforeHello = agents.prompts.length
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "hello" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === promptCountBeforeHello + 1)
    expect(agents.prompts).toContainEqual([session.agentSessionId, "hello"])
    const promptCountBeforeRetry = agents.prompts.length
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
    await waitFor(() => agents.prompts.length === promptCountBeforeRetry + 1)
    expect(agents.prompts).toEqual(
      expect.arrayContaining([
        [session.agentSessionId, "hello"],
        [session.agentSessionId, "retry once"]
      ])
    )
    const promptCountBeforeRawChunks = agents.prompts.length
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "raw chunks" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === promptCountBeforeRawChunks + 1)
    let rawConversation: ReadonlyArray<string> = []
    let rawEvents: ReadonlyArray<unknown> = []
    await waitFor(
      async () => {
        rawConversation = (await run(services.db.getSessionDetail(session.id))).conversation.map(
          (item) => item.text
        )
        rawEvents = await run(services.db.listSubjectEvents(session.id))
        return rawConversation.includes("Raw answer without id")
      },
      () => JSON.stringify({ rawConversation, rawEvents })
    )
    expect(
      (await run(services.db.getSessionDetail(session.id))).conversation.map((item) => item.text)
    ).toEqual(
      expect.arrayContaining(["hello", "Echo: hello", "raw chunks", "Raw answer without id"])
    )
    expect(await run(services.db.listSubjectEvents(session.id))).toEqual(
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
    const scopedReplay = (await readWebSocketEvents(
      server,
      2,
      0,
      `/v1/sessions/${session.id}/events/socket`
    )) as Array<{ id: number; subjectId: string; subjectRevision?: number }>
    expect(scopedReplay.every((event) => event.subjectId === session.id)).toBe(true)
    expect(scopedReplay.map((event) => event.id)).toEqual([1, 2])
    expect(scopedReplay.map((event) => event.subjectRevision)).toEqual([1, 2])
    const transcriptResponse = await jsonRequest(
      server,
      `/v1/sessions/${session.id}/transcript?limit=2`
    )
    expect(transcriptResponse.status).toBe(200)
    const transcript = transcriptResponse.body as {
      items: Array<{ id: string; role: string; text: string }>
      hasMore: boolean
      eventCursor: number
    }
    expect(transcript.items.length).toBeLessThanOrEqual(2)
    expect(transcript.items.some((item) => item.role === "assistant")).toBe(true)
    expect(transcript.eventCursor).toBeGreaterThan(0)
    expect((await jsonRequest(server, `/v1/sessions/${session.id}/transcript`)).status).toBe(200)
    const assistantTranscriptItem = transcript.items.find((item) => item.role === "assistant")!
    const transcriptDetails = await jsonRequest(
      server,
      `/v1/sessions/${session.id}/transcript/${assistantTranscriptItem.id}/details`
    )
    expect(transcriptDetails.status).toBe(200)
    expect(transcriptDetails.body).toMatchObject({ itemId: assistantTranscriptItem.id })
    expect(
      (
        transcriptDetails.body as {
          events: Array<{ subjectId: string }>
        }
      ).events.every((event) => event.subjectId === session.id)
    ).toBe(true)
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript?before=wat`)
    ).toMatchObject({ status: 400 })
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript?before=-1`)
    ).toMatchObject({ status: 400 })
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript?limit=wat`)
    ).toMatchObject({ status: 400 })
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript?limit=0`)
    ).toMatchObject({ status: 400 })
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript/missing/details`)
    ).toMatchObject({ status: 404 })
    const promptCountBeforeReturnedEvents = agents.prompts.length
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "returned events" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === promptCountBeforeReturnedEvents + 1)
    expect(
      (await run(services.db.getSessionDetail(session.id))).conversation.map((item) => item.text)
    ).toEqual(expect.arrayContaining(["returned events", "Raw answer without id"]))

    const promptCountBeforeSlow = agents.prompts.length
    const queueEventsBeforeSlow = (await run(services.db.listSubjectEvents(session.id))).filter(
      (event) => event.kind === "session.queue.updated"
    ).length
    const slowResponse = (
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "slow prompt" }),
        method: "POST"
      })
    ).body as { readonly queueItemId: string }
    expect(slowResponse.queueItemId).toBeTypeOf("string")
    await waitFor(() => agents.prompts.length === promptCountBeforeSlow + 1)
    const immediatePromptQueueEvents = (await run(services.db.listSubjectEvents(session.id)))
      .filter((event) => event.kind === "session.queue.updated")
      .slice(queueEventsBeforeSlow)
    expect(immediatePromptQueueEvents).not.toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          payload: expect.objectContaining({
            queue: expect.arrayContaining([
              expect.objectContaining({ id: slowResponse.queueItemId })
            ])
          })
        })
      ])
    )
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
    const promptCountBeforeQueueDrain = agents.prompts.length
    await waitFor(() => agents.prompts.length === promptCountBeforeQueueDrain + 1)
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
      (await run(services.db.listSubjectEvents(session.id))).some(
        (event) => event.kind === "session.error"
      )
    )
    expect(agents.loads).toContainEqual(["codex", session.agentSessionId, workspaceFolder])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/connect`, {
          method: "POST"
        })
      ).body
    ).toMatchObject({
      configOptions: [
        {
          currentValue: "gpt-current",
          id: "model",
          options: [{ value: "gpt-current" }, { value: "gpt-new" }]
        }
      ],
      sessionId: session.agentSessionId
    })
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

    // Goal set: the double-option tokenBudget key only forwards when present.
    const goalResponse = await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
      body: JSON.stringify({ clientActionId: "goal-1", objective: "ship it", tokenBudget: 50000 }),
      method: "POST"
    })
    expect(goalResponse.status).toBe(202)
    expect(goalResponse.body).toMatchObject({
      objective: "ship it",
      status: "active",
      tokenBudget: 50000
    })
    expect(agents.goals).toEqual([
      [session.agentSessionId, { objective: "ship it", tokenBudget: 50000 }]
    ])
    // Idempotent replay: the same clientActionId returns the stored result
    // without re-invoking the runtime.
    const goalReplay = await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
      body: JSON.stringify({ clientActionId: "goal-1", objective: "ship it", tokenBudget: 50000 }),
      method: "POST"
    })
    expect(goalReplay.status).toBe(202)
    expect(agents.goals).toHaveLength(1)
    // Pause keeps the budget key off the wire entirely.
    await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
      body: JSON.stringify({ status: "paused" }),
      method: "POST"
    })
    expect(agents.goals.at(-1)).toEqual([session.agentSessionId, { status: "paused" }])
    // Explicit null clears the budget.
    await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
      body: JSON.stringify({ tokenBudget: null }),
      method: "POST"
    })
    expect(agents.goals.at(-1)).toEqual([session.agentSessionId, { tokenBudget: null }])
    // Bad payloads are rejected before reaching the runtime.
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
          body: JSON.stringify({ status: "someday" }),
          method: "POST"
        })
      ).status
    ).toBe(400)
    // Runtime failures (e.g. goals unsupported by the harness) surface as errors.
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
          body: JSON.stringify({ objective: "goal fails" }),
          method: "POST"
        })
      ).status
    ).toBeGreaterThanOrEqual(400)
    // Clear.
    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/goal`, { method: "DELETE" })).status
    ).toBe(204)
    expect(agents.goalClears).toEqual([session.agentSessionId])

    // Question answers route to the runtime, with idempotent replay.
    const answerBody = {
      answers: { approach: { answers: ["MVP first"], note: "keep it lean" } },
      clientActionId: "answer-1",
      outcome: "answered"
    }
    const answerResponse = await jsonRequest(
      server,
      `/v1/sessions/${session.id}/questions/q-1/answer`,
      {
        body: JSON.stringify(answerBody),
        method: "POST"
      }
    )
    expect(answerResponse.status).toBe(202)
    expect(answerResponse.body).toEqual({ outcome: "answered", questionId: "q-1" })
    await jsonRequest(server, `/v1/sessions/${session.id}/questions/q-1/answer`, {
      body: JSON.stringify(answerBody),
      method: "POST"
    })
    expect(agents.questionAnswers).toEqual([
      [
        session.agentSessionId,
        "q-1",
        {
          answers: { approach: { answers: ["MVP first"], note: "keep it lean" } },
          outcome: "answered"
        }
      ]
    ])
    // Cancel outcome forwards without answers.
    await jsonRequest(server, `/v1/sessions/${session.id}/questions/q-2/answer`, {
      body: JSON.stringify({ outcome: "cancelled" }),
      method: "POST"
    })
    expect(agents.questionAnswers.at(-1)).toEqual([
      session.agentSessionId,
      "q-2",
      { outcome: "cancelled" }
    ])
    // Bad payloads 400 before reaching the runtime; stale questions surface errors.
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/questions/q-3/answer`, {
          body: JSON.stringify({ outcome: "maybe" }),
          method: "POST"
        })
      ).status
    ).toBe(400)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/questions/stale-question/answer`, {
          body: JSON.stringify({ outcome: "answered" }),
          method: "POST"
        })
      ).status
    ).toBeGreaterThanOrEqual(400)

    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}`, {
          body: JSON.stringify({ title: "Retitled" }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ isArchived: false, title: "Retitled" })
    // Retitling never touches the runtime.
    expect(agents.closes).toEqual([])

    // Archiving retires the runtime: the agent session closes and its
    // background-task terminals (and only those) are killed and removed.
    const backgroundProcess = { killCount: 0 }
    const backgroundTerminal = services.terminal.registerExternalTerminal(
      { sessionId: `${session.agentSessionId}:bg:tool-1` },
      {
        kill: () => {
          backgroundProcess.killCount += 1
        },
        resize: () => undefined,
        write: () => undefined
      }
    )
    const unrelatedTerminal = services.terminal.registerExternalTerminal(
      { sessionId: "other-session:bg:tool-9" },
      { kill: () => undefined, resize: () => undefined, write: () => undefined }
    )
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}`, {
          body: JSON.stringify({ isArchived: true }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ isArchived: true })
    expect(agents.closes).toEqual([session.agentSessionId])
    expect(backgroundProcess.killCount).toBe(1)
    await expect(
      run(services.terminal.terminalFrames(backgroundTerminal.terminalId))
    ).rejects.toBeInstanceOf(TerminalError)
    expect(await run(services.terminal.terminalFrames(unrelatedTerminal.terminalId))).toEqual([])

    // A session with no runtime identity archives without touching the runtime.
    const runtimelessSession = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          agentSessionId: "",
          harnessId: "codex",
          projectId: workspace.id,
          title: "Imported"
        }),
        method: "POST"
      })
    ).body as { readonly id: string }
    await jsonRequest(server, `/v1/sessions/${runtimelessSession.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(agents.closes).toEqual([session.agentSessionId])
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

  it("deduplicates concurrent client session creation while creation is pending", async () => {
    const { agents, services } = await makeServices("server-a")
    const server = await startWithApp(services)
    runningServers.push(server)
    const projectRoot = mkdtempSync(join(tmpdir(), "codevisor-server-pending-create-"))
    tempDirs.push(projectRoot)
    const workspaceFolder = join(projectRoot, "workspace")
    mkdirSync(workspaceFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: workspaceFolder, id: "pending-create-project" }),
        method: "POST"
      })
    ).body as { readonly id: string }

    const sessionBody = JSON.stringify({
      id: "client-session-pending-create",
      projectId: project.id,
      harnessId: "codex",
      title: "Pending create"
    })
    const [first, second] = await Promise.all([
      jsonRequest(server, "/v1/sessions", {
        body: sessionBody,
        method: "POST"
      }),
      jsonRequest(server, "/v1/sessions", {
        body: sessionBody,
        method: "POST"
      })
    ])
    expect([first.status, second.status].sort()).toEqual([200, 201])
    expect(first.body).toEqual(second.body)
    expect(agents.creations).toEqual([["codex", workspaceFolder]])
  })

  it("opens a session in one round-trip, creating project and session only when missing", async () => {
    const { agents, server } = await start()
    const projectRoot = mkdtempSync(join(tmpdir(), "codevisor-server-open-"))
    tempDirs.push(projectRoot)
    const workspaceFolder = join(projectRoot, "workspace")
    mkdirSync(workspaceFolder)

    // First open: nothing exists server-side — both records are created and
    // the first transcript page comes back, all in one request.
    const opened = await jsonRequest(server, "/v1/sessions/open-session-1/open", {
      body: JSON.stringify({
        project: { folderPath: workspaceFolder, id: "open-project-1" },
        session: {
          harnessId: "codex",
          id: "open-session-1",
          projectId: "open-project-1",
          title: "Open flow"
        },
        transcriptLimit: 8
      }),
      method: "POST"
    })
    expect(opened.status).toBe(200)
    expect(opened.body).toMatchObject({
      session: { id: "open-session-1", projectId: "open-project-1", title: "Open flow" },
      transcript: { hasMore: false, items: [] }
    })
    expect(agents.creations).toEqual([["codex", workspaceFolder]])

    const unchanged = await jsonRequest(server, "/v1/sessions/open-session-1/open", {
      body: JSON.stringify({
        session: { harnessId: "codex", projectId: "open-project-1" }
      }),
      method: "POST"
    })
    expect(unchanged.status).toBe(200)
    expect(unchanged.body).toMatchObject({ session: { title: "Open flow" } })

    // Archive the project, then re-open with the original (now stale)
    // snapshot: the existing project must NOT be reverted to unarchived, the
    // session must not be re-created, and the update payload applies.
    await jsonRequest(server, "/v1/projects/open-project-1", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    const reopened = await jsonRequest(server, "/v1/sessions/open-session-1/open", {
      body: JSON.stringify({
        project: { folderPath: workspaceFolder, id: "open-project-1" },
        session: {
          harnessId: "codex",
          id: "open-session-1",
          projectId: "open-project-1",
          title: "Open flow"
        },
        update: { title: "Renamed on open" }
      }),
      method: "POST"
    })
    expect(reopened.status).toBe(200)
    expect(reopened.body).toMatchObject({ session: { title: "Renamed on open" } })
    expect(agents.creations).toHaveLength(1)
    const projects = (await jsonRequest(server, "/v1/projects")).body as ReadonlyArray<{
      readonly id: string
      readonly isArchived: boolean
    }>
    expect(projects.find((candidate) => candidate.id === "open-project-1")?.isArchived).toBe(true)

    // A body/path session-id mismatch is rejected before any writes.
    expect(
      (
        await jsonRequest(server, "/v1/sessions/other-id/open", {
          body: JSON.stringify({
            session: { harnessId: "codex", id: "open-session-1", projectId: "open-project-1" }
          }),
          method: "POST"
        })
      ).status
    ).toBe(400)

    // Invalid transcript limits are rejected before any writes.
    expect(
      (
        await jsonRequest(server, "/v1/sessions/open-session-1/open", {
          body: JSON.stringify({
            session: { harnessId: "codex", projectId: "open-project-1" },
            transcriptLimit: 0
          }),
          method: "POST"
        })
      ).status
    ).toBe(400)

    // An open naming an unknown project with no project payload still 404s.
    expect(
      (
        await jsonRequest(server, "/v1/sessions/orphan-session/open", {
          body: JSON.stringify({
            session: { harnessId: "codex", id: "orphan-session", projectId: "missing-project" }
          }),
          method: "POST"
        })
      ).status
    ).toBe(404)
  })

  it("serves pane workspaces with idempotent PUTs and change events", async () => {
    const { server, services } = await start()
    const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-workspaces-"))
    tempDirs.push(workspaceRoot)
    const projectFolder = join(workspaceRoot, "project")
    mkdirSync(projectFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: projectFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }

    expect(await jsonRequest(server, "/v1/workspaces")).toEqual({ status: 200, body: [] })

    const put = await jsonRequest(server, "/v1/workspaces/workspace-1", {
      body: JSON.stringify({ projectId: project.id, name: "Main", hasCustomName: false }),
      method: "PUT"
    })
    expect(put.status).toBe(200)
    expect(put.body).toMatchObject({
      id: "workspace-1",
      serverId: "server-a",
      projectId: project.id,
      name: "Main",
      hasCustomName: false,
      isArchived: false
    })

    // A body id matching the path is allowed; the second PUT updates in place
    // and publishes the same workspace.updated kind as the create.
    const replayBeforePut = await run(services.db.listEvents(0))
    const livePut = readSseEvents(server, 1, replayBeforePut.at(-1)?.id ?? 0)
    const renamed = await jsonRequest(server, "/v1/workspaces/workspace-1", {
      body: JSON.stringify({
        id: "workspace-1",
        projectId: project.id,
        name: "Renamed",
        hasCustomName: true,
        symbolName: "hammer",
        rootDirectory: projectFolder,
        isArchived: false
      }),
      method: "PUT"
    })
    expect(renamed.status).toBe(200)
    expect(renamed.body).toMatchObject({
      name: "Renamed",
      hasCustomName: true,
      symbolName: "hammer",
      rootDirectory: projectFolder
    })
    expect((renamed.body as { readonly updatedAt?: string }).updatedAt).toBeDefined()
    expect(await livePut).toEqual([
      expect.objectContaining({
        kind: "workspace.updated",
        subjectId: "workspace-1",
        payload: expect.objectContaining({ name: "Renamed" })
      })
    ])
    expect((await jsonRequest(server, "/v1/workspaces")).body).toMatchObject([
      { id: "workspace-1", name: "Renamed" }
    ])

    // Sessions can be created directly into a workspace.
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: project.id,
          harnessId: "codex",
          workspaceId: "workspace-1"
        }),
        method: "POST"
      })
    ).body as { readonly id: string; readonly workspaceId?: string }
    expect(session.workspaceId).toBe("workspace-1")

    // A body id that disagrees with the path is rejected before any write.
    expect(
      (
        await jsonRequest(server, "/v1/workspaces/workspace-1", {
          body: JSON.stringify({
            id: "other",
            projectId: project.id,
            name: "Nope",
            hasCustomName: false
          }),
          method: "PUT"
        })
      ).status
    ).toBe(400)

    // Missing rows surface exactly like the project routes' database errors.
    expect(
      (
        await jsonRequest(server, "/v1/workspaces/workspace-2", {
          body: JSON.stringify({ projectId: "missing", name: "Nope", hasCustomName: false }),
          method: "PUT"
        })
      ).status
    ).toBe(500)
    expect((await jsonRequest(server, "/v1/workspaces/missing", { method: "DELETE" })).status).toBe(
      500
    )

    // A workspace that still owns a session is protected by its foreign key.
    expect(
      (await jsonRequest(server, "/v1/workspaces/workspace-1", { method: "DELETE" })).status
    ).toBe(500)
    await jsonRequest(server, `/v1/sessions/${session.id}`, { method: "DELETE" })

    const replayBeforeDelete = await run(services.db.listEvents(0))
    const liveDelete = readSseEvents(server, 1, replayBeforeDelete.at(-1)?.id ?? 0)
    expect(
      (await jsonRequest(server, "/v1/workspaces/workspace-1", { method: "DELETE" })).status
    ).toBe(204)
    expect(await liveDelete).toEqual([
      expect.objectContaining({
        kind: "workspace.deleted",
        subjectId: "workspace-1",
        payload: { id: "workspace-1" }
      })
    ])
    expect(await run(services.db.listEvents(0))).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "workspace.updated",
          subjectId: "workspace-1",
          payload: expect.objectContaining({ name: "Main" })
        }),
        expect.objectContaining({ kind: "workspace.deleted", subjectId: "workspace-1" })
      ])
    )

    // Unmatched workspace methods fall through to the 404 handler.
    expect((await jsonRequest(server, "/v1/workspaces", { method: "POST" })).status).toBe(404)
  })

  it("serves workspace notes with last-write-wins PUTs and change events", async () => {
    const { server, services } = await start()
    const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-workspace-notes-"))
    tempDirs.push(workspaceRoot)
    const projectFolder = join(workspaceRoot, "project")
    mkdirSync(projectFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: projectFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    expect(
      (
        await jsonRequest(server, "/v1/workspaces/workspace-1", {
          body: JSON.stringify({ projectId: project.id, name: "Main", hasCustomName: false }),
          method: "PUT"
        })
      ).status
    ).toBe(200)

    // Clients read this 404 as "no notes yet", not as a failure.
    const empty = await jsonRequest(server, "/v1/workspaces/workspace-1/notes")
    expect(empty.status).toBe(404)
    expect(empty.body).toEqual({ error: "Workspace notes not found: workspace-1" })

    // A PUT saves the scratchpad and fans out the full record so connected
    // clients can live-apply the change without a refetch.
    const replayBeforePut = await run(services.db.listEvents(0))
    const livePut = readSseEvents(server, 1, replayBeforePut.at(-1)?.id ?? 0)
    const saved = await jsonRequest(server, "/v1/workspaces/workspace-1/notes", {
      body: JSON.stringify({
        content: '{"runs":[{"text":"hello"}]}',
        updatedAt: "2026-07-10T00:00:00.000Z"
      }),
      method: "PUT"
    })
    expect(saved).toEqual({
      status: 200,
      body: {
        workspaceId: "workspace-1",
        content: '{"runs":[{"text":"hello"}]}',
        format: "attributed-string-v1",
        updatedAt: "2026-07-10T00:00:00.000Z"
      }
    })
    expect(await livePut).toEqual([
      expect.objectContaining({
        kind: "workspace.notes.updated",
        subjectId: "workspace-1",
        payload: expect.objectContaining({
          content: '{"runs":[{"text":"hello"}]}',
          updatedAt: "2026-07-10T00:00:00.000Z"
        })
      })
    ])
    expect(await jsonRequest(server, "/v1/workspaces/workspace-1/notes")).toEqual(saved)

    // The newest write replaces the row outright — last write wins.
    const replaced = await jsonRequest(server, "/v1/workspaces/workspace-1/notes", {
      body: JSON.stringify({
        content: '{"runs":[{"text":"replaced"}]}',
        format: "markdown-v1",
        updatedAt: "2026-07-11T00:00:00.000Z"
      }),
      method: "PUT"
    })
    expect(replaced.body).toMatchObject({
      content: '{"runs":[{"text":"replaced"}]}',
      format: "markdown-v1",
      updatedAt: "2026-07-11T00:00:00.000Z"
    })
    expect((await jsonRequest(server, "/v1/workspaces/workspace-1/notes")).body).toEqual(
      replaced.body
    )

    // Missing workspaces surface like the other workspace routes' database
    // errors.
    const missing = await jsonRequest(server, "/v1/workspaces/missing/notes", {
      body: JSON.stringify({ content: "{}" }),
      method: "PUT"
    })
    expect(missing.status).toBe(500)
    expect(missing.body).toMatchObject({ error: expect.stringContaining("missing") })

    // Unmatched notes methods fall through to the 404 handler.
    expect(
      (await jsonRequest(server, "/v1/workspaces/workspace-1/notes", { method: "POST" })).status
    ).toBe(404)
  })

  it("persists and fans out agent-initiated events with no prompt in flight", async () => {
    const { agents, server, services } = await start()
    const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-background-"))
    tempDirs.push(workspaceRoot)
    const workspaceFolder = join(workspaceRoot, "codevisor")
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

    const sessionEvents = await run(services.db.listSubjectEvents(session.id))
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
    const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-subagent-"))
    tempDirs.push(workspaceRoot)
    const workspaceFolder = join(workspaceRoot, "codevisor")
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
    const events = await run(services.db.listSubjectEvents(session.id))
    expect(events).toEqual(
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

  it("lists directories for the remote project picker", async () => {
    const { server } = await start()
    const root = mkdtempSync(join(tmpdir(), "codevisor-fs-"))
    tempDirs.push(root)
    mkdirSync(join(root, "beta"))
    mkdirSync(join(root, "Alpha", ".git"), { recursive: true })
    mkdirSync(join(root, ".hidden"))
    writeFileSync(join(root, "file.txt"), "not a directory")

    const listing = await jsonRequest(server, `/v1/fs/list?path=${encodeURIComponent(root)}`)
    expect(listing.status).toBe(200)
    expect(listing.body).toMatchObject({
      path: root,
      parent: dirname(root),
      entries: [
        { name: "Alpha", path: join(root, "Alpha"), isGitRepo: true },
        { name: "beta", path: join(root, "beta"), isGitRepo: false }
      ]
    })

    const withHidden = await jsonRequest(
      server,
      `/v1/fs/list?path=${encodeURIComponent(root)}&showHidden=true`
    )
    expect((withHidden.body as { entries: Array<{ name: string }> }).entries[0]?.name).toBe(
      ".hidden"
    )

    // Home expansion: bare "~" and "~/..." resolve against the server's home.
    const home = await jsonRequest(server, "/v1/fs/list")
    expect(home.status).toBe(200)
    expect((home.body as { path: string }).path.startsWith("/")).toBe(true)

    // The filesystem root has no parent.
    const rootListing = await jsonRequest(server, "/v1/fs/list?path=/")
    expect((rootListing.body as { parent: string | null }).parent).toBeNull()

    // "~/…" paths expand under the server's home.
    const homeChild = await jsonRequest(server, "/v1/fs/list?path=%7E%2F")
    expect(homeChild.status).toBe(200)

    const missing = await jsonRequest(
      server,
      `/v1/fs/list?path=${encodeURIComponent(join(root, "nope"))}`
    )
    expect(missing.status).toBe(404)
    expect(missing.body).toMatchObject({ code: "not_found" })

    const notDir = await jsonRequest(
      server,
      `/v1/fs/list?path=${encodeURIComponent(join(root, "file.txt"))}`
    )
    expect(notDir.status).toBe(400)
    expect(notDir.body).toMatchObject({ code: "not_a_directory" })

    const relative = await jsonRequest(server, "/v1/fs/list?path=relative/path")
    expect(relative.status).toBe(400)
    expect(relative.body).toMatchObject({ code: "invalid_path" })

    // Symlinks: follow directory links, skip broken ones and plain files.
    const linked = mkdtempSync(join(tmpdir(), "codevisor-fs-links-"))
    tempDirs.push(linked)
    symlinkSync(join(root, "beta"), join(linked, "beta-link"))
    symlinkSync(join(root, "gone"), join(linked, "broken-link"))
    symlinkSync(join(root, "file.txt"), join(linked, "file-link"))
    const links = await jsonRequest(server, `/v1/fs/list?path=${encodeURIComponent(linked)}`)
    expect((links.body as { entries: Array<{ name: string }> }).entries.map((e) => e.name)).toEqual(
      ["beta-link"]
    )

    // Unreadable directories surface a permission error, not a crash.
    const sealed = join(root, "sealed")
    mkdirSync(sealed, { mode: 0o000 })
    const denied = await jsonRequest(server, `/v1/fs/list?path=${encodeURIComponent(sealed)}`)
    chmodSync(sealed, 0o755)
    expect(denied.status).toBe(403)
    expect(denied.body).toMatchObject({ code: "permission_denied" })
  })

  it("clones a git remote into the managed repos dir as a project", async () => {
    const execFileAsync = promisify(execFile)
    const git = (args: ReadonlyArray<string>, cwd: string) =>
      execFileAsync("git", [...args], { cwd })

    const reposRoot = mkdtempSync(join(tmpdir(), "codevisor-repos-"))
    tempDirs.push(reposRoot)
    process.env["CODEVISOR_REPOS_ROOT"] = reposRoot
    try {
      const { server, services } = await start()
      const origin = mkdtempSync(join(tmpdir(), "codevisor-origin-"))
      tempDirs.push(origin)
      const originRepo = join(origin, "widget.git")
      mkdirSync(originRepo)
      await git(["init"], originRepo)
      writeFileSync(join(originRepo, "README.md"), "hello")
      await git(["add", "."], originRepo)
      await git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "init"], originRepo)

      const url = `file://${originRepo}`
      const created = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ id: "cloned-project", url }),
        method: "POST"
      })
      expect(created.status).toBe(201)
      expect(created.body).toMatchObject({
        id: "cloned-project",
        name: "widget",
        repoUrl: url,
        locations: [{ folderPath: join(reposRoot, "widget"), isGitRepository: true }]
      })
      expect(existsSync(join(reposRoot, "widget", "README.md"))).toBe(true)

      // Clone progress reached the event log under the client-supplied id.
      const events = await run(services.db.listSubjectEvents("cloned-project"))
      const states = events
        .filter((event) => event.kind === "project.setup")
        .map((event) => (event.payload as { state: string }).state)
      expect(states[0]).toBe("started")
      expect(states.at(-1)).toBe("completed")

      // A second clone of the same remote under an explicit name gets its
      // own directory and a server-generated project id.
      const renamed = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url, name: "widget-two" }),
        method: "POST"
      })
      expect(renamed.status).toBe(201)
      expect(renamed.body).toMatchObject({
        name: "widget-two",
        locations: [{ folderPath: join(reposRoot, "widget-two") }]
      })

      // Same destination again: conflict, with an actionable code.
      const duplicate = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url }),
        method: "POST"
      })
      expect(duplicate.status).toBe(409)
      expect(duplicate.body).toMatchObject({ code: "already_exists" })

      // Not a git URL at all.
      const invalid = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url: "not a url" }),
        method: "POST"
      })
      expect(invalid.status).toBe(400)
      expect(invalid.body).toMatchObject({ code: "invalid_url" })

      // A URL no project name can be derived from (scp-style syntax).
      const unnameable = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url: "git@example.com:acme/--.git" }),
        method: "POST"
      })
      expect(unnameable.status).toBe(400)
      expect((unnameable.body as { error: string }).error).toContain("name")

      // A well-formed URL to a repo that does not exist: the clone fails with
      // a classified error, publishes `failed`, and leaves no partial dir.
      const missing = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ id: "missing-project", url: `file://${origin}/gone.git` }),
        method: "POST"
      })
      expect(missing.status).toBe(422)
      expect((missing.body as { code?: string }).code).toBeDefined()
      expect(existsSync(join(reposRoot, "gone"))).toBe(false)
      const failedEvents = await run(services.db.listSubjectEvents("missing-project"))
      expect(
        failedEvents.some(
          (event) =>
            event.kind === "project.setup" &&
            (event.payload as { state: string }).state === "failed"
        )
      ).toBe(true)
    } finally {
      delete process.env["CODEVISOR_REPOS_ROOT"]
    }
  })

  it("addresses projects by id case-insensitively", async () => {
    const { server } = await start()
    const lowerId = "0d604f39-364b-4a17-8fd8-21bddd8c1399"
    const upperId = lowerId.toUpperCase()

    // A client that sends an uppercase UUID (Swift) has it canonicalized to
    // lowercase, so ids stay consistent across clients.
    const created = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/case-project", id: upperId }),
      method: "POST"
    })
    expect(created.status).toBe(201)
    expect((created.body as { id: string }).id).toBe(lowerId)

    // Re-syncing the same project (uppercase again) is idempotent — no
    // duplicate row, no merge into a differently-cased id.
    const resync = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/case-project", id: upperId }),
      method: "POST"
    })
    expect((resync.body as { id: string }).id).toBe(lowerId)
    expect(((await jsonRequest(server, "/v1/projects")).body as Array<unknown>).length).toBe(1)

    // A client that stores the id uppercase (Swift's UUID) resolves the
    // lowercase-stored project instead of hitting a spurious "Project not
    // found". (A later 4xx for harness/account reasons is unrelated.)
    const session = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({ projectId: upperId, harnessId: "codex" }),
      method: "POST"
    })
    expect(session.status).not.toBe(404)
    expect(JSON.stringify(session.body)).not.toContain("Project not found")

    // The worktree route resolves the project by the uppercase URL id too.
    const worktree = await jsonRequest(server, `/v1/projects/${upperId}/worktrees`, {
      body: JSON.stringify({ name: "feature" }),
      method: "POST"
    })
    expect(worktree.status).not.toBe(404)
    expect(JSON.stringify(worktree.body)).not.toContain("Project not found")
  })

  it("creates worktrees and runs worktree sessions in them", async () => {
    const execFileAsync = promisify(execFile)
    const git = (args: ReadonlyArray<string>, cwd: string) =>
      execFileAsync("git", [...args], { cwd })

    const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-worktrees-"))
    tempDirs.push(worktreesRoot)
    process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
    try {
      const { agents, server, services } = await start()
      // makeServices' temp dir (the newest entry) holds the server database.
      const serverDatabasePath = join(tempDirs[tempDirs.length - 1] as string, "codevisor.sqlite")
      const repoRoot = mkdtempSync(join(tmpdir(), "codevisor-repo-"))
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
        body: JSON.stringify({
          id: "wt-fix-auth",
          name: "Fix Auth!",
          sessionId: "session-awaiting-worktree"
        }),
        method: "POST"
      })
      expect(worktreeResponse.status).toBe(201)
      const worktree = worktreeResponse.body as {
        readonly id: string
        readonly name: string
        readonly branch: string
        readonly path: string
      }
      expect(worktree).toMatchObject({
        id: "wt-fix-auth",
        projectId: "git-project",
        serverId: "server-a"
      })
      // A custom name stays clean when it is available.
      expect(worktree.name).toBe("fix-auth")
      expect(worktree.branch).toBe(`codevisor/${worktree.name}`)
      expect(worktree.path).toBe(join(worktreesRoot, "git-project", worktree.name))
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
        name: worktree.name,
        branch: worktree.branch
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
      const mirroredSetupPayloads = (await run(services.db.listEvents(0))).filter(
        (event) =>
          event.kind === "worktree.setup" && event.subjectId === "session-awaiting-worktree"
      )
      expect(
        mirroredSetupPayloads.map((event) => (event.payload as { state: string }).state)
      ).toEqual(setupPayloads.map((payload) => payload.state))
      const mirroredSetupHistory = (
        await jsonRequest(server, "/v1/sessions/session-awaiting-worktree/events")
      ).body as ReadonlyArray<{ readonly kind: string; readonly subjectId: string }>
      expect(mirroredSetupHistory).toHaveLength(mirroredSetupPayloads.length)
      expect(mirroredSetupHistory.every((event) => event.kind === "worktree.setup")).toBe(true)

      // Repeated custom names get a readable sequence number.
      const secondWorktree = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "fix auth" }),
          method: "POST"
        })
      ).body as { readonly name: string; readonly branch: string }
      expect(secondWorktree.name).toBe("fix-auth-2")
      expect(secondWorktree.branch).toBe(`codevisor/${secondWorktree.name}`)
      const thirdWorktree = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "fix auth" }),
          method: "POST"
        })
      ).body as { readonly name: string; readonly branch: string }
      expect(thirdWorktree.name).toBe("fix-auth-3")
      expect(thirdWorktree.branch).toBe(`codevisor/${thirdWorktree.name}`)
      // Missing names get a compact food word from the curated production pool.
      const randomNamed = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          method: "POST"
        })
      ).body as { readonly name: string; readonly branch: string }
      expect(productionFoodWorktreeNames).toContain(randomNamed.name)
      expect(randomNamed.branch).toBe(`codevisor/${randomNamed.name}`)
      expect(
        ((await jsonRequest(server, "/v1/projects/git-project/worktrees")).body as Array<unknown>)
          .length
      ).toBe(4)

      // Git refs outlive archived database rows and are shared by isolated
      // development servers. A stale branch is included in allocation, so
      // the request transparently moves to the next readable name.
      await git(["branch", "codevisor/doomed"], repoFolder)
      const recovered = await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        body: JSON.stringify({ id: "wt-doomed", name: "doomed" }),
        method: "POST"
      })
      expect(recovered.status).toBe(201)
      expect(recovered.body).toMatchObject({
        id: "wt-doomed",
        name: "doomed-2",
        branch: "codevisor/doomed-2"
      })
      const recoveredSetup = (await run(services.db.listEvents(0)))
        .filter((event) => event.kind === "worktree.setup" && event.subjectId === "wt-doomed")
        .map((event) => (event.payload as { readonly state: string }).state)
      expect(recoveredSetup[0]).toBe("started")
      expect(recoveredSetup.at(-1)).toBe("completed")
      expect(recoveredSetup).not.toContain("failed")
      expect(
        ((await jsonRequest(server, "/v1/projects/git-project/worktrees")).body as Array<unknown>)
          .length
      ).toBe(5)

      // Sessions created with a worktree run the agent inside the worktree.
      const sessionResponse = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: "git-project",
          harnessId: "codex",
          worktreeName: worktree.name,
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
      expect(session.worktreeName).toBe(worktree.name)
      expect(session.cwd).toBe(worktree.path)
      expect(agents.creations).toContainEqual(["codex", worktree.path])
      const sessionHistory = (await jsonRequest(server, `/v1/sessions/${session.id}/events`))
        .body as ReadonlyArray<{ readonly kind: string; readonly subjectId: string }>
      expect(sessionHistory).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ kind: "worktree.setup", subjectId: worktree.id })
        ])
      )

      // Reattaching (prompt after restart) resolves the same worktree cwd.
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "hello worktree" }),
        method: "POST"
      })
      await waitFor(() => agents.prompts.some((prompt) => prompt[1] === "hello worktree"))
      expect(agents.loads).toContainEqual(["codex", session.agentSessionId, worktree.path])

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
      const removedWorktreeHistory = (await jsonRequest(server, `/v1/sessions/${sharer.id}/events`))
        .body as ReadonlyArray<{ readonly kind: string }>
      expect(removedWorktreeHistory.some((event) => event.kind === "worktree.setup")).toBe(false)

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
          worktreeName: worktree.name,
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
      delete process.env["CODEVISOR_WORKTREES_ROOT"]
    }
  })

  it("uses food names with four-digit suffixes for development worktrees", async () => {
    const execFileAsync = promisify(execFile)
    const git = (args: ReadonlyArray<string>, cwd: string) =>
      execFileAsync("git", [...args], { cwd })
    const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-development-worktrees-"))
    tempDirs.push(worktreesRoot)
    process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
    try {
      const { services } = await makeServices("server-dev")
      const server = await run(
        startCodevisorServer(
          services,
          defaultServerConfig({
            id: "server-dev",
            port: 0,
            worktreeNameStyle: "development"
          })
        )
      )
      runningServers.push(server)
      const repoFolder = mkdtempSync(join(tmpdir(), "codevisor-development-repo-"))
      tempDirs.push(repoFolder)
      await git(["init"], repoFolder)
      await git(
        ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
        repoFolder
      )
      expect(
        (
          await jsonRequest(server, "/v1/projects", {
            body: JSON.stringify({ folderPath: repoFolder, id: "food-project" }),
            method: "POST"
          })
        ).status
      ).toBe(201)

      const response = await jsonRequest(server, "/v1/projects/food-project/worktrees", {
        method: "POST"
      })
      expect(response.status).toBe(201)
      const name = (response.body as { readonly name: string }).name
      const match = /^(.*)-(\d{4})$/.exec(name)
      expect(match).not.toBeNull()
      expect(foodWorktreeNames).toContain(match?.[1])
    } finally {
      delete process.env["CODEVISOR_WORKTREES_ROOT"]
    }
  })

  it("stores files and threads prompt attachments end to end", async () => {
    const { agents, server, services } = await start()
    const projectRoot = mkdtempSync(join(tmpdir(), "codevisor-server-attachments-"))
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
    const root = join(tmpdir(), "codevisor-attachments")
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
      body: JSON.stringify({
        sessionId: "session-kill",
        cwd: "/tmp/codevisor",
        cols: 80,
        rows: 24
      }),
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
      body: JSON.stringify({ sessionId: "session-1", cwd: "/tmp/codevisor", cols: 80, rows: 24 }),
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

  it("falls back to the session server's project location for branch diffs", async () => {
    const { services } = await makeServices("server-a")
    const project = await run(services.db.createProject({ folderPath: "/tmp" }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    const { cwd: _cwd, ...withoutCwd } = session
    let projectedServerId = "server-a"
    const server = await startWithApp({
      ...services,
      db: {
        ...services.db,
        getSessionSummary: (id) =>
          id === session.id
            ? Effect.succeed({ ...withoutCwd, serverId: projectedServerId })
            : services.db.getSessionSummary(id)
      }
    })
    runningServers.push(server)

    expect(await jsonRequest(server, `/v1/sessions/${session.id}/branch-diff`)).toEqual({
      body: null,
      status: 200
    })
    projectedServerId = "server-without-location"
    expect(await jsonRequest(server, `/v1/sessions/${session.id}/branch-diff`)).toEqual({
      body: null,
      status: 200
    })
  })

  it("reports session harness usage limits with workspace and account context", async () => {
    const { services } = await makeServices("server-a")
    const project = await run(services.db.createProject({ folderPath: "/tmp" }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    const { cwd: _cwd, ...withoutCwd } = session
    let projectedSession = session
    const readHarnessUsageLimits = vi.fn((harnessId: string, cwd: string) =>
      Effect.succeed({
        fetchedAt: "2026-07-15T00:00:00.000Z",
        harnessId,
        state: "available" as const,
        windows: [{ id: "five-hour", label: cwd, usedPercent: 25 }]
      })
    )
    const routeServices = {
      ...services,
      agents: { ...services.agents, readHarnessUsageLimits },
      db: {
        ...services.db,
        getSessionSummary: (id: string) =>
          id === session.id ? Effect.succeed(projectedSession) : services.db.getSessionSummary(id)
      }
    }
    const server = await startWithApp(routeServices)
    runningServers.push(server)

    expect(await jsonRequest(server, `/v1/sessions/${session.id}/usage-limits`)).toMatchObject({
      body: {
        harnessId: "codex",
        state: "available",
        windows: [{ label: "/tmp" }]
      },
      status: 200
    })
    expect((await jsonRequest(server, "/v1/sessions/missing/usage-limits")).status).toBe(404)

    const accounts = [
      {
        id: "other-account",
        harnessId: "codex",
        profileKind: "default" as const,
        label: "Other",
        authState: "authenticated" as const,
        isActive: false,
        canLogin: true,
        canLogout: true
      },
      {
        id: "active-account",
        harnessId: "codex",
        profileKind: "default" as const,
        label: "Active",
        email: "active@example.com",
        authState: "authenticated" as const,
        isActive: true,
        canLogin: true,
        canLogout: true
      }
    ]
    const auth = {
      accounts: vi.fn(async () => accounts),
      accountContext: vi.fn(async (id: string) => ({ id, profileKind: "default" as const })),
      activeAccountContext: vi.fn(async () => ({
        id: "active-account",
        profileKind: "default" as const
      })),
      subscribe: () => () => undefined
    } as unknown as HarnessAuthManager
    const authenticatedServer = await startWithApp({ ...routeServices, auth })
    runningServers.push(authenticatedServer)

    projectedSession = { ...withoutCwd, serverId: "server-a" }
    expect(
      await jsonRequest(authenticatedServer, `/v1/sessions/${session.id}/usage-limits`)
    ).toMatchObject({
      body: {
        accountEmail: "active@example.com",
        accountId: "active-account",
        accountLabel: "Active",
        state: "available"
      },
      status: 200
    })
    expect(auth.activeAccountContext).toHaveBeenCalledWith("codex")

    projectedSession = {
      ...withoutCwd,
      harnessAccountId: "explicit-account",
      serverId: "server-a"
    }
    expect(
      await jsonRequest(authenticatedServer, `/v1/sessions/${session.id}/usage-limits`)
    ).toMatchObject({
      body: { accountId: "explicit-account", state: "available" },
      status: 200
    })
    expect(auth.accountContext).toHaveBeenCalledWith("explicit-account")

    projectedSession = { ...withoutCwd, serverId: "remote-server" }
    expect(
      await jsonRequest(authenticatedServer, `/v1/sessions/${session.id}/usage-limits`)
    ).toMatchObject({
      body: {
        detail: "This session has no local workspace from which to query its harness.",
        harnessId: "codex",
        state: "unavailable",
        windows: []
      },
      status: 200
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
          listEvents: (since) =>
            since >= Number.MAX_SAFE_INTEGER
              ? Effect.succeed([])
              : Effect.promise(async () => {
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
    const liveOnly = readWebSocketEvents(server, 1, Number.MAX_SAFE_INTEGER)
    await new Promise((resolve) => setTimeout(resolve, 20))
    const afterSnapshot = { ...liveEvent, id: 3, payload: { id: "after-snapshot" } }
    await run(fanout.publish(afterSnapshot))
    expect(await liveOnly).toEqual([afterSnapshot])

    const globalFiltered = readWebSocketEvents(server, 1, Number.MAX_SAFE_INTEGER)
    await new Promise((resolve) => setTimeout(resolve, 20))
    await run(
      fanout.publish({
        ...afterSnapshot,
        id: 4,
        subjectId: "session-only",
        subjectRevision: 1
      })
    )
    const globalAfterFilter = { ...afterSnapshot, id: 5, subjectId: "global-after-filter" }
    await run(fanout.publish(globalAfterFilter))
    expect(await globalFiltered).toEqual([globalAfterFilter])

    const scopedFiltered = readWebSocketEvents(
      server,
      1,
      Number.MAX_SAFE_INTEGER,
      "/v1/sessions/target-session/events/socket"
    )
    await new Promise((resolve) => setTimeout(resolve, 20))
    await run(
      fanout.publish({
        ...afterSnapshot,
        id: 6,
        subjectId: "other-session",
        subjectRevision: 1
      })
    )
    const scopedAfterFilter = {
      ...afterSnapshot,
      id: 7,
      subjectId: "target-session",
      subjectRevision: 2
    }
    await run(fanout.publish(scopedAfterFilter))
    expect(await scopedFiltered).toEqual([{ ...scopedAfterFilter, id: 2 }])

    const sseFiltered = readSseEvents(server, 1, Number.MAX_SAFE_INTEGER)
    await new Promise((resolve) => setTimeout(resolve, 20))
    await run(
      fanout.publish({
        ...afterSnapshot,
        id: 8,
        subjectId: "session-only-sse",
        subjectRevision: 1
      })
    )
    const globalSseEvent = { ...afterSnapshot, id: 9, subjectId: "global-sse" }
    await run(fanout.publish(globalSseEvent))
    expect(await sseFiltered).toEqual([globalSseEvent])
  })

  it("exposes an Effect service layer and EventFanout subscription", async () => {
    const { services } = await makeServices("layered")
    const layered = await run(
      Effect.gen(function* () {
        const server = yield* CodevisorServer
        return yield* server.db.getUpdateInfo
      }).pipe(Effect.provide(CodevisorServer.layer(services)))
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

  describe("custom harness routes", () => {
    const makeStore = () => {
      const replaced: Array<ReadonlyArray<unknown>> = []
      const tested: Array<unknown> = []
      return {
        replaced,
        tested,
        store: {
          list: async () => [{ command: "my-agent", id: "mine", name: "Mine" }],
          replace: async (specs: ReadonlyArray<unknown>) => {
            replaced.push(specs)
          },
          test: async (spec: unknown) => {
            tested.push(spec)
            return { agentName: "Mine", ok: true, protocolVersion: 1 }
          }
        }
      }
    }

    it("lists custom harnesses", async () => {
      const { services } = await makeServices("server-a")
      const { store } = makeStore()
      const server = await startWithApp({ ...services, customHarnesses: store })
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/custom")
      expect(response.status).toBe(200)
      expect(response.body).toEqual({
        harnesses: [{ command: "my-agent", id: "mine", name: "Mine" }]
      })
    })

    it("replaces the list and returns the refreshed harness catalog", async () => {
      const { services } = await makeServices("server-a")
      const { replaced, store } = makeStore()
      const server = await startWithApp({ ...services, customHarnesses: store })
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/custom", {
        body: JSON.stringify({
          harnesses: [{ args: ["acp"], command: "my-agent", id: "mine", name: "Mine" }]
        }),
        method: "PUT"
      })
      expect(response.status).toBe(200)
      // Blocking rescan semantics: the fresh discovery list comes back.
      expect(response.body).toMatchObject([{ id: "codex" }])
      expect(replaced).toEqual([[{ args: ["acp"], command: "my-agent", id: "mine", name: "Mine" }]])
    })

    it("rejects invalid replacement lists without persisting", async () => {
      const { services } = await makeServices("server-a")
      const { replaced, store } = makeStore()
      const server = await startWithApp({ ...services, customHarnesses: store })
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/custom", {
        body: JSON.stringify({
          harnesses: [{ command: "fake-codex", id: "codex", name: "Fake Codex" }]
        }),
        method: "PUT"
      })
      expect(response.status).toBe(400)
      expect(replaced).toEqual([])
    })

    it("runs the ACP handshake test for a spec", async () => {
      const { services } = await makeServices("server-a")
      const { store, tested } = makeStore()
      const server = await startWithApp({ ...services, customHarnesses: store })
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/custom/test", {
        body: JSON.stringify({ command: "my-agent", id: "mine", name: "Mine" }),
        method: "POST"
      })
      expect(response.status).toBe(200)
      expect(response.body).toEqual({ agentName: "Mine", ok: true, protocolVersion: 1 })
      expect(tested).toHaveLength(1)
    })

    it("rejects an invalid test spec", async () => {
      const { services } = await makeServices("server-a")
      const { store, tested } = makeStore()
      const server = await startWithApp({ ...services, customHarnesses: store })
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/custom/test", {
        body: JSON.stringify({ command: "", id: "bad", name: "Bad" }),
        method: "POST"
      })
      expect(response.status).toBe(400)
      expect(tested).toEqual([])
    })

    it("returns 501 when the host has no custom-harness store", async () => {
      const { services } = await makeServices("server-a")
      const server = await startWithApp(services)
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/custom")
      expect(response.status).toBe(501)
    })
  })

  describe("harness update checks", () => {
    it("forces a check and returns the decorated harness list", async () => {
      const { services } = await makeServices("server-a")
      const checks: Array<boolean> = []
      const lifecycle = {
        beginBundledAppUpdate: async () => {},
        beginInstall: async () => ({ terminalId: "unused" }),
        beginUpdate: async () => ({ queued: false }),
        bundledAppInfo: async () => undefined,
        cancelPendingUpdate: async () => {},
        checkForUpdates: async (force?: boolean) => {
          checks.push(force === true)
          return []
        },
        decorateHarnesses: async (list: ReadonlyArray<Harness>) =>
          list.map((harness) => ({
            ...harness,
            updateInfo: { latestVersion: "9.9.9", updateAvailable: true }
          })),
        forcePendingUpdate: async () => {},
        installMethods: async () => [],
        isGated: () => false,
        notifyTurnEnded: () => {},
        notifyTurnStarted: () => {},
        onGateReleased: () => () => {},
        reconcileOnStartup: async () => {},
        startPeriodicChecks: () => () => {},
        subscribe: () => () => {}
      }
      const server = await startWithApp({ ...services, lifecycle })
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/check-updates", { method: "POST" })
      expect(response.status).toBe(200)
      expect(checks).toEqual([true])
      expect(response.body).toMatchObject([
        { id: "codex", updateInfo: { latestVersion: "9.9.9", updateAvailable: true } }
      ])

      // Lifecycle decoration is opt-in: the plain list (the composer picker's
      // path) skips it, ?include=lifecycle carries it.
      const plain = await jsonRequest(server, "/v1/harnesses")
      expect((plain.body as Array<{ updateInfo?: unknown }>)[0]?.updateInfo).toBeUndefined()
      const decorated = await jsonRequest(server, "/v1/harnesses?include=lifecycle")
      expect(decorated.body).toMatchObject([{ id: "codex", updateInfo: { updateAvailable: true } }])
    })

    it("drives install, update, pending, and bundled-app routes", async () => {
      const { services } = await makeServices("server-a")
      const calls: Array<string> = []
      const lifecycle = {
        beginBundledAppUpdate: async (id: string) => {
          if (id !== "codex") throw new Error("no bundled desktop app")
          calls.push(`bundled-update ${id}`)
        },
        beginInstall: async (id: string, methodId?: string) => {
          // Non-Error throw exercises the conflict mapping's String branch.
          // oxlint-disable-next-line no-throw-literal
          if (methodId === "carrier-pigeon") throw "no runnable install method"
          calls.push(`install ${id} ${methodId ?? "auto"}`)
          return { terminalId: "terminal-9" }
        },
        beginUpdate: async (id: string) => {
          if (id === "kimi") throw new Error("kimi has no update source")
          calls.push(`update ${id}`)
          return { queued: true }
        },
        bundledAppInfo: async (id: string) =>
          id === "codex"
            ? {
                appName: "ChatGPT",
                bundlePath: "/Applications/ChatGPT.app",
                installedVersion: "1.0",
                latestVersion: "2.0",
                updateAvailable: true
              }
            : undefined,
        cancelPendingUpdate: async (id: string) => {
          if (id !== "codex") throw new Error("No pending update")
          calls.push(`cancel ${id}`)
        },
        checkForUpdates: async () => [],
        decorateHarnesses: async (list: ReadonlyArray<Harness>) => list,
        forcePendingUpdate: async (id: string) => {
          if (id !== "codex") throw new Error("No pending update")
          calls.push(`force ${id}`)
        },
        installMethods: async () => [],
        isGated: () => false,
        notifyTurnEnded: () => {},
        notifyTurnStarted: () => {},
        onGateReleased: () => () => {},
        reconcileOnStartup: async () => {},
        startPeriodicChecks: () => () => {},
        subscribe: () => () => {}
      }
      const server = await startWithApp({ ...services, lifecycle })
      runningServers.push(server)

      const install = await jsonRequest(server, "/v1/harnesses/codex/install", {
        body: JSON.stringify({ methodId: "brew" }),
        method: "POST"
      })
      expect(install.status).toBe(202)
      expect(install.body).toMatchObject({ accepted: true, terminalId: "terminal-9" })
      // Method omitted → the server resolves the recommended one.
      const autoInstall = await jsonRequest(server, "/v1/harnesses/codex/install", {
        body: JSON.stringify({}),
        method: "POST"
      })
      expect(autoInstall.status).toBe(202)
      const badInstall = await jsonRequest(server, "/v1/harnesses/codex/install", {
        body: JSON.stringify({ methodId: "carrier-pigeon" }),
        method: "POST"
      })
      expect(badInstall.status).toBe(409)
      expect(badInstall.body).toMatchObject({ error: "no runnable install method" })

      // Custom-harness collection accepts only GET/PUT — other verbs fall
      // through to later routes rather than mutating the store.
      const wrongMethod = await jsonRequest(server, "/v1/harnesses/custom", {
        body: JSON.stringify({}),
        method: "POST"
      })
      expect(wrongMethod.status).toBeGreaterThanOrEqual(400)

      const update = await jsonRequest(server, "/v1/harnesses/codex/update", { method: "POST" })
      expect(update.status).toBe(202)
      expect(update.body).toMatchObject({ accepted: true, queued: true })
      const badUpdate = await jsonRequest(server, "/v1/harnesses/kimi/update", { method: "POST" })
      expect(badUpdate.status).toBe(409)

      const pendingApply = await jsonRequest(server, "/v1/harnesses/codex/update/pending/apply", {
        method: "POST"
      })
      expect(pendingApply.status).toBe(202)
      const badApply = await jsonRequest(server, "/v1/harnesses/gemini/update/pending/apply", {
        method: "POST"
      })
      expect(badApply.status).toBe(409)
      const pendingCancel = await jsonRequest(server, "/v1/harnesses/codex/update/pending", {
        method: "DELETE"
      })
      expect(pendingCancel.status).toBe(204)
      const badCancel = await jsonRequest(server, "/v1/harnesses/gemini/update/pending", {
        method: "DELETE"
      })
      expect(badCancel.status).toBe(409)

      const bundled = await jsonRequest(server, "/v1/harnesses/codex/bundled-app")
      expect(bundled.status).toBe(200)
      expect(bundled.body).toMatchObject({ appName: "ChatGPT", updateAvailable: true })
      const noBundle = await jsonRequest(server, "/v1/harnesses/gemini/bundled-app")
      expect(noBundle.status).toBe(404)
      const bundledUpdate = await jsonRequest(server, "/v1/harnesses/codex/bundled-app/update", {
        method: "POST"
      })
      expect(bundledUpdate.status).toBe(202)
      const badBundled = await jsonRequest(server, "/v1/harnesses/gemini/bundled-app/update", {
        method: "POST"
      })
      expect(badBundled.status).toBe(409)

      expect(calls).toEqual([
        "install codex brew",
        "install codex auto",
        "update codex",
        "force codex",
        "cancel codex",
        "bundled-update codex"
      ])
    })

    it("returns 501 without a lifecycle manager", async () => {
      const { services } = await makeServices("server-a")
      const server = await startWithApp(services)
      runningServers.push(server)

      for (const [path, method] of [
        ["/v1/harnesses/check-updates", "POST"],
        ["/v1/harnesses/codex/install", "POST"],
        ["/v1/harnesses/codex/update", "POST"],
        ["/v1/harnesses/codex/update/pending/apply", "POST"],
        ["/v1/harnesses/codex/update/pending", "DELETE"],
        ["/v1/harnesses/codex/bundled-app", "GET"],
        ["/v1/harnesses/codex/bundled-app/update", "POST"],
        ["/v1/harnesses/custom/test", "POST"]
      ] as const) {
        const response = await jsonRequest(server, path, { method })
        expect(response.status, `${method} ${path}`).toBe(501)
      }
    })

    it("holds prompts while the harness update gate is closed and dispatches on release", async () => {
      const { agents, services } = await makeServices("server-a")
      const gated = new Set<string>()
      const turns: Array<string> = []
      let releaseListener: ((harnessId: string) => void) | undefined
      const lifecycle = {
        beginBundledAppUpdate: async () => {},
        beginInstall: async () => ({ terminalId: "unused" }),
        beginUpdate: async () => ({ queued: false }),
        bundledAppInfo: async () => undefined,
        cancelPendingUpdate: async () => {},
        checkForUpdates: async () => [],
        decorateHarnesses: async (list: ReadonlyArray<Harness>) => list,
        forcePendingUpdate: async () => {},
        installMethods: async () => [],
        isGated: (harnessId: string) => gated.has(harnessId),
        notifyTurnEnded: (harnessId: string) => turns.push(`end ${harnessId}`),
        notifyTurnStarted: (harnessId: string) => turns.push(`start ${harnessId}`),
        onGateReleased: (listener: (harnessId: string) => void) => {
          releaseListener = listener
          return () => {}
        },
        reconcileOnStartup: async () => {},
        startPeriodicChecks: () => () => {},
        subscribe: () => () => {}
      }
      const server = await startWithApp({ ...services, lifecycle })
      runningServers.push(server)

      const folder = join(mkdtempSync(join(tmpdir(), "codevisor-gate-")), "repo")
      mkdirSync(folder, { recursive: true })
      const project = (
        await jsonRequest(server, "/v1/projects", {
          body: JSON.stringify({ folderPath: folder }),
          method: "POST"
        })
      ).body as { readonly id: string }
      const session = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ harnessId: "codex", projectId: project.id, title: "Gated" }),
          method: "POST"
        })
      ).body as { readonly id: string }

      // Gate closed: the prompt is accepted (202, durable) but never reaches
      // the provider.
      gated.add("codex")
      const accepted = await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "held prompt" }),
        method: "POST"
      })
      expect(accepted.status).toBe(202)
      // A second send while held re-queues without a duplicate hold marker.
      const second = await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "also held" }),
        method: "POST"
      })
      expect(second.status).toBe(202)
      await new Promise((resolve) => setTimeout(resolve, 150))
      expect(agents.prompts).toHaveLength(0)
      // The transcript-facing hold marker was persisted for replay.
      const heldEvents = await run(services.db.listSubjectEvents(session.id))
      expect(
        heldEvents.some(
          (event) =>
            event.kind === "session.updateGate.updated" &&
            (event.payload as { state?: string }).state === "waiting"
        )
      ).toBe(true)

      // A release for a different harness leaves this session held.
      releaseListener?.("gemini")
      await new Promise((resolve) => setTimeout(resolve, 100))
      expect(agents.prompts).toHaveLength(0)

      // Gate releases → the held prompts dispatch and turn accounting ran.
      gated.delete("codex")
      releaseListener?.("codex")
      await waitFor(() => agents.prompts.length === 2)
      expect(agents.prompts[0]?.[1]).toBe("held prompt")
      await waitFor(() => turns.includes("end codex"))
      expect(turns[0]).toBe("start codex")
    })
  })
})

describe("native MCP and skills routes", () => {
  const nativeMcpScan: NativeMcpScan = {
    candidates: [
      {
        alreadyManaged: false,
        args: ["-y", "docs-mcp"],
        command: "npx",
        foundIn: ["claude-code"],
        identity: "docs-mcp",
        name: "docs",
        transport: "stdio"
      }
    ],
    harnesses: [
      {
        configPath: "/home/u/.claude.json",
        exists: true,
        harnessId: "claude-code",
        harnessName: "Claude Code",
        harnessSymbol: "sparkle",
        servers: []
      }
    ]
  }

  const skillsScan: SkillsScan = {
    canonicalDir: "/home/u/.agents/skills",
    global: [
      {
        directoryName: "deploy",
        installs: [{ harnessId: "claude-code", state: "linked" }],
        name: "Deploy",
        path: "/home/u/.agents/skills/deploy"
      }
    ],
    harnesses: [
      {
        harnessId: "claude-code",
        harnessName: "Claude Code",
        harnessSymbol: "sparkle",
        skills: [],
        skillsDir: "/home/u/.claude/skills"
      }
    ]
  }

  const nativeMcpRemoval = {
    configPath: "/home/u/.claude.json",
    harnessId: "claude-code",
    id: "removal-1",
    removedAt: "2026-07-20T00:00:00.000Z",
    serverName: "docs"
  }

  const nativeMcpStub = (calls: Array<unknown[]>) => ({
    importServers: async (request: { identities: ReadonlyArray<string> }) => ({
      outcomes: request.identities.map((identity) => ({
        identity,
        status: "imported" as const,
        warnings: []
      })),
      scan: nativeMcpScan
    }),
    listRemovals: async () => [nativeMcpRemoval],
    removeServer: async (harnessId: string, serverName: string) => {
      calls.push(["removeServer", harnessId, serverName])
      return { removal: nativeMcpRemoval, scan: nativeMcpScan }
    },
    restoreRemoval: async (id: string) => {
      calls.push(["restoreRemoval", id])
      return nativeMcpScan
    },
    scan: async () => nativeMcpScan,
    setNativeEnabled: async (harnessId: string, serverName: string, enabled: boolean) => {
      calls.push(["setNativeEnabled", harnessId, serverName, enabled])
      return nativeMcpScan
    }
  })

  const skillsStub = (calls: Array<unknown[]>) => ({
    create: async (request: unknown) => {
      calls.push(["create", request])
      return skillsScan
    },
    importLocal: async (request: unknown) => {
      calls.push(["importLocal", request])
      return skillsScan
    },
    importRemote: async (request: unknown) => {
      calls.push(["importRemote", request])
      return skillsScan
    },
    sync: async (request?: unknown) => {
      calls.push(["sync", request])
      return skillsScan
    },
    discoverRemote: async (request: unknown) => {
      calls.push(["discoverRemote", request])
      return {
        skills: [{ alreadyExists: false, directoryName: "deploy", name: "Deploy" } as const]
      }
    },
    list: async () => skillsScan,
    makeGlobal: async (harnessId: string, directoryName: string) => {
      calls.push(["makeGlobal", harnessId, directoryName])
      return skillsScan
    },
    remove: async (directoryName: string) => {
      calls.push(["remove", directoryName])
      return skillsScan
    },
    setInstalled: async (directoryName: string, harnessId: string, installed: boolean) => {
      calls.push(["setInstalled", directoryName, harnessId, installed])
      return skillsScan
    }
  })

  it("serves scans from the configured managers", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp({
      ...services,
      nativeMcp: nativeMcpStub([]),
      skills: skillsStub([])
    })
    runningServers.push(server)

    const nativeResponse = await jsonRequest(server, "/v1/native-mcps")
    expect(nativeResponse.status).toBe(200)
    expect(nativeResponse.body).toEqual(nativeMcpScan)

    const importResponse = await jsonRequest(server, "/v1/native-mcps/import", {
      body: JSON.stringify({ identities: ["docs-mcp"] }),
      method: "POST"
    })
    expect(importResponse.status).toBe(200)
    expect(importResponse.body).toEqual({
      outcomes: [{ identity: "docs-mcp", status: "imported", warnings: [] }],
      scan: nativeMcpScan
    })

    const skillsResponse = await jsonRequest(server, "/v1/skills")
    expect(skillsResponse.status).toBe(200)
    expect(skillsResponse.body).toEqual(skillsScan)

    // Unknown methods and subpaths fall through to 404.
    expect((await jsonRequest(server, "/v1/native-mcps", { method: "POST" })).status).toBe(404)
    expect((await jsonRequest(server, "/v1/native-mcps/unknown")).status).toBe(404)
    expect((await jsonRequest(server, "/v1/skills/unknown")).status).toBe(404)
    expect((await jsonRequest(server, "/v1/skills/unknown", { method: "PATCH" })).status).toBe(404)
    expect((await jsonRequest(server, "/v1/skills", { method: "PATCH" })).status).toBe(404)
  })

  it("routes native MCP destructive operations to the manager", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<unknown[]> = []
    const server = await startWithApp({ ...services, nativeMcp: nativeMcpStub(calls) })
    runningServers.push(server)

    const removeResponse = await jsonRequest(server, "/v1/native-mcps/remove", {
      body: JSON.stringify({ harnessId: "claude-code", serverName: "docs" }),
      method: "POST"
    })
    expect(removeResponse.status).toBe(200)
    expect(removeResponse.body).toEqual({ removal: nativeMcpRemoval, scan: nativeMcpScan })

    const removalsResponse = await jsonRequest(server, "/v1/native-mcps/removals")
    expect(removalsResponse.status).toBe(200)
    expect(removalsResponse.body).toEqual([nativeMcpRemoval])

    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/removals/removal-1/restore", {
          method: "POST"
        })
      ).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/removals/removal-1/unknown", {
          method: "POST"
        })
      ).status
    ).toBe(404)

    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/set-enabled", {
          body: JSON.stringify({ enabled: false, harnessId: "opencode", serverName: "local" }),
          method: "POST"
        })
      ).status
    ).toBe(200)

    expect(calls).toEqual([
      ["removeServer", "claude-code", "docs"],
      ["restoreRemoval", "removal-1"],
      ["setNativeEnabled", "opencode", "local", false]
    ])
  })

  it("maps NativeMcpError codes onto HTTP statuses", async () => {
    const { services } = await makeServices("server-a")
    const failing = {
      ...nativeMcpStub([]),
      removeServer: async () => {
        throw new NativeMcpError("can't edit safely", "unsupported")
      },
      restoreRemoval: async () => {
        throw new NativeMcpError("name in use", "conflict")
      },
      setNativeEnabled: async () => {
        throw new NativeMcpError("no such server", "notFound")
      }
    }
    const server = await startWithApp({ ...services, nativeMcp: failing })
    runningServers.push(server)

    const unsupported = await jsonRequest(server, "/v1/native-mcps/remove", {
      body: JSON.stringify({ harnessId: "goose", serverName: "docs" }),
      method: "POST"
    })
    expect(unsupported.status).toBe(422)
    expect(unsupported.body).toEqual({ code: "unsupported", error: "can't edit safely" })
    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/removals/removal-1/restore", {
          method: "POST"
        })
      ).status
    ).toBe(409)
    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/set-enabled", {
          body: JSON.stringify({ enabled: true, harnessId: "opencode", serverName: "ghost" }),
          method: "POST"
        })
      ).status
    ).toBe(404)
  })

  it("routes skills CRUD operations to the manager", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<unknown[]> = []
    const server = await startWithApp({ ...services, skills: skillsStub(calls) })
    runningServers.push(server)

    expect(
      (
        await jsonRequest(server, "/v1/skills", {
          body: JSON.stringify({ description: "Deploy checklist", name: "Deploy" }),
          method: "POST"
        })
      ).status
    ).toBe(201)
    expect(
      (
        await jsonRequest(server, "/v1/skills/import", {
          body: JSON.stringify({ path: "/tmp/deploy" }),
          method: "POST"
        })
      ).status
    ).toBe(201)
    expect(
      (
        await jsonRequest(server, "/v1/skills/import-remote", {
          body: JSON.stringify({ source: "vercel-labs/skills" }),
          method: "POST"
        })
      ).status
    ).toBe(201)
    expect(
      (
        await jsonRequest(server, "/v1/skills/make-global", {
          body: JSON.stringify({ directoryName: "ship-it", harnessId: "claude-code" }),
          method: "POST"
        })
      ).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(server, "/v1/skills/sync", {
          body: JSON.stringify({}),
          method: "POST"
        })
      ).status
    ).toBe(200)
    const discovered = await jsonRequest(server, "/v1/skills/discover-remote", {
      body: JSON.stringify({ source: "vercel-labs/skills" }),
      method: "POST"
    })
    expect(discovered.status).toBe(200)
    expect(discovered.body).toEqual({
      skills: [{ alreadyExists: false, directoryName: "deploy", name: "Deploy" }]
    })
    expect(
      (
        await jsonRequest(server, "/v1/skills/deploy/harnesses/claude-code", {
          body: JSON.stringify({ installed: true }),
          method: "PUT"
        })
      ).status
    ).toBe(200)
    expect((await jsonRequest(server, "/v1/skills/deploy", { method: "DELETE" })).status).toBe(200)

    expect(calls).toEqual([
      ["create", { description: "Deploy checklist", name: "Deploy" }],
      ["importLocal", { path: "/tmp/deploy" }],
      ["importRemote", { source: "vercel-labs/skills" }],
      ["makeGlobal", "claude-code", "ship-it"],
      ["sync", {}],
      ["discoverRemote", { source: "vercel-labs/skills" }],
      ["setInstalled", "deploy", "claude-code", true],
      ["remove", "deploy"]
    ])
  })

  it("maps SkillsError codes onto HTTP statuses", async () => {
    const { services } = await makeServices("server-a")
    const failing = {
      ...skillsStub([]),
      create: async () => {
        throw new SkillsError("already exists", "conflict")
      },
      importLocal: async () => {
        throw new SkillsError("not a directory", "invalid")
      },
      remove: async () => {
        throw new SkillsError("no such skill", "notFound")
      }
    }
    const server = await startWithApp({ ...services, skills: failing })
    runningServers.push(server)

    const conflict = await jsonRequest(server, "/v1/skills", {
      body: JSON.stringify({ description: "", name: "deploy" }),
      method: "POST"
    })
    expect(conflict.status).toBe(409)
    expect(conflict.body).toEqual({ code: "conflict", error: "already exists" })
    expect(
      (
        await jsonRequest(server, "/v1/skills/import", {
          body: JSON.stringify({ path: "/tmp/nope" }),
          method: "POST"
        })
      ).status
    ).toBe(400)
    expect((await jsonRequest(server, "/v1/skills/deploy", { method: "DELETE" })).status).toBe(404)
  })

  it("returns 501 when the host has no native MCP or skills managers", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp(services)
    runningServers.push(server)
    expect((await jsonRequest(server, "/v1/native-mcps")).status).toBe(501)
    expect((await jsonRequest(server, "/v1/skills")).status).toBe(501)
  })
})
