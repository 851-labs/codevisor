import {
  harnessCatalog,
  type AgentRuntimeService,
  type PromptInput,
  type QuestionAnswer,
  type RuntimeEvent,
  type RuntimeEventSink,
  type SetGoalUpdate
} from "@codevisor/agent-runtime"
import type { Harness, NativeMcpScan, SessionConfigOption, SkillsScan } from "@codevisor/api"
import { PluginsError, type PluginsManager, type PluginStateEvent } from "@codevisor/plugins"
import { makeAttachmentStore, makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
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
  startCodevisorServer,
  type RunningCodevisorServer
} from "./server.js"
import type { CodevisorServerConfig, CodevisorServerServices } from "./server.js"
import { makeMcpManager } from "@codevisor/mcp"

export const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export const configSelectionsFromTestOptions = (
  options: ReadonlyArray<SessionConfigOption>
): Readonly<Record<string, string>> =>
  Object.fromEntries(options.map((option) => [option.id, option.currentValue]))

export const harnesses: ReadonlyArray<Harness> = [
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

export const makeAgents = (): AgentRuntimeService & {
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
  readonly inspectionConfigs: Array<Readonly<Record<string, string>> | undefined>
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
  const inspectionConfigs: Array<Readonly<Record<string, string>> | undefined> = []
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
    inspectionConfigs,
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
    inspectHarness: (harnessId, cwd, _account, configSelections) =>
      Effect.sync(() => {
        inspections.push([harnessId, cwd])
        inspectionConfigs.push(configSelections)
        if (cwd.includes("capability-fail")) {
          throw new Error("capability probe failed")
        }
        if (cwd.includes("no-modes")) {
          return {
            sessionId: `inspect-${harnessId}`,
            configOptions: []
          }
        }
        const model = configSelections?.model ?? "gpt-5"
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
              currentValue: model,
              options: [{ value: "gpt-5", name: "GPT-5" }]
            },
            {
              id: "reasoning",
              name: "Reasoning",
              category: "thought_level",
              currentValue: model === "gpt-next" ? "high" : "medium",
              options:
                model === "gpt-next"
                  ? [{ value: "high", name: "High" }]
                  : [{ value: "medium", name: "Medium" }]
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
        const text = typeof input === "string" ? input : input.text
        prompts.push([sessionId, input])
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
        return { runtimeState: "reusable" as const }
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
  const mcp = makeMcpManager({ db, dataDir: dir })
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

export const nativeMcpScan: NativeMcpScan = {
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

export const skillsScan: SkillsScan = {
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

export const nativeMcpRemoval = {
  configPath: "/home/u/.claude.json",
  harnessId: "claude-code",
  id: "removal-1",
  removedAt: "2026-07-20T00:00:00.000Z",
  serverName: "docs"
}

/// Shared plugins-manager stub for the plugin route suites (same role as
/// nativeMcpStub/skillsStub below): records calls and mirrors the real
/// manager's typed failures.
export const pluginSummary = {
  id: "owner.example",
  name: "Example",
  panes: [{ path: "/panes/main/", title: "Main", type: "main" }],
  path: "/tmp/example",
  source: "linked",
  state: "stopped",
  version: "0.1.0"
} as const

export const pluginsStub = (
  calls: Array<Array<unknown>>,
  listeners: Array<(event: PluginStateEvent) => void> = []
): PluginsManager => ({
  close: () => calls.push(["close"]),
  startAll: async () => {
    calls.push(["startAll"])
  },
  discoverRemote: async (request) => {
    calls.push(["discoverRemote", request])
    if (request.source === "ghost/missing") {
      throw new PluginsError("invalid", "No codevisor-plugin.json found in ghost/missing")
    }
    return {
      alreadyInstalled: false,
      description: "Example plugin",
      id: "owner.example",
      installCommand: "bun install",
      name: "Example",
      panes: pluginSummary.panes,
      runCommand: "bun run start",
      version: "0.1.0"
    }
  },
  importRemote: async (request) => {
    calls.push(["importRemote", request])
    if (request.source === "other/taken") {
      throw new PluginsError("conflict", "already provided by dev-checkout")
    }
    return { ...pluginSummary, source: "managed" }
  },
  fetchIcon: async (pluginId, paneType) => {
    calls.push(["fetchIcon", pluginId, paneType])
    return { contentType: "image/png", data: new Uint8Array([1, 2, 3]) }
  },
  link: async (request) => {
    calls.push(["link", request])
    if (request.path === "relative/path") {
      throw new PluginsError("invalid", "Plugin link path must be absolute")
    }
    return pluginSummary
  },
  remove: async (pluginId) => {
    calls.push(["remove", pluginId])
    if (pluginId !== "owner.example") {
      throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
    }
    return { plugins: [] }
  },
  get: async (pluginId) => {
    calls.push(["get", pluginId])
    if (pluginId === "owner.conflict") {
      throw new PluginsError("conflict", "conflicting install")
    }
    if (pluginId === "owner.invalid") {
      throw new PluginsError("invalid", "broken manifest")
    }
    if (pluginId === "owner.unavailable") {
      throw new PluginsError("unavailable", "circuit breaker is open")
    }
    if (pluginId !== "owner.example") {
      throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
    }
    return pluginSummary
  },
  handleProxyRequest: async (_request, response, url) => {
    // Mirror the real manager: only proxy-shaped paths are handled here.
    if (!url.pathname.includes("/app/") || url.pathname.endsWith("/unhandled/")) {
      return false
    }
    calls.push(["proxy", url.pathname])
    response.writeHead(200, { "Content-Type": "text/html" })
    response.end("<html>pane</html>")
    return true
  },
  handleUpgrade: async (request, socket) => {
    const url = new URL(request.url ?? "/", "http://127.0.0.1")
    if (url.pathname.endsWith("/unhandled")) {
      return false
    }
    calls.push(["upgrade", url.pathname])
    socket.write("HTTP/1.1 418 Plugin Socket\r\nConnection: close\r\n\r\n")
    socket.destroy()
    return true
  },
  invokeTool: async (pluginId, toolName, args, context) => {
    calls.push(["invokeTool", pluginId, toolName, args, context])
    if (pluginId !== "owner.example") {
      throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
    }
    if (toolName !== "notes_add") {
      throw new PluginsError("notFound", `Plugin ${pluginId} has no tool: ${toolName}`)
    }
    return { added: true, received: args }
  },
  listTools: async () => {
    calls.push(["listTools"])
    return [{ description: "Append a note", name: "notes_add", pluginId: "owner.example" }]
  },
  subscribeInstalled: (listener) => {
    calls.push(["subscribeInstalled", listener])
    return () => calls.push(["unsubscribeInstalled"])
  },
  issuePaneToken: async (pluginId, paneId, request) => {
    calls.push(["issuePaneToken", pluginId, paneId, request])
    return {
      expiresAt: new Date().toISOString(),
      path: `/v1/plugins/${pluginId}/app/panes/${request.paneType}/?paneId=${paneId}&codevisorPaneToken=tok`,
      token: "tok"
    }
  },
  list: async () => {
    calls.push(["list"])
    return { plugins: [pluginSummary] }
  },
  restart: async (pluginId) => {
    calls.push(["restart", pluginId])
    if (pluginId !== "owner.example") {
      throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
    }
    return pluginSummary
  },
  subscribe: (listener) => {
    listeners.push(listener)
    return () => calls.push(["unsubscribe"])
  }
})

export const nativeMcpStub = (calls: Array<unknown[]>) => ({
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

export const skillsStub = (calls: Array<unknown[]>) => ({
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
  },
  syncManaged: async () => {}
})
