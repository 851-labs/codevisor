import { Effect } from "effect"
import type {
  HarnessDefinition,
  ProviderEnvironment,
  RuntimeEvent,
  ToolGatewayConfig
} from "@codevisor/agent-runtime"
import type { CodexClient, CodexSpawnRequest } from "./client.js"
import { makeCodexProvider } from "./provider.js"

export const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

export const definition: HarnessDefinition = {
  detectBinaries: ["codex"],
  id: "codex",
  name: "Codex",
  provider: "codex",
  symbolName: "chevron.left.forwardslash.chevron.right"
}

export const environment: ProviderEnvironment = {
  env: { PATH: "/bin" },
  executableExists: (name) => name === "codex",
  locateExecutable: (name) => (name === "codex" ? "/bin/codex" : undefined)
}

export class FakeCodexClient implements CodexClient {
  readonly pid = 4242
  readonly requests: Array<{ method: string; params: unknown }> = []
  readonly notifications: Array<{ method: string; params: unknown }> = []
  private notificationHandler: ((method: string, params: unknown) => void) | undefined
  private requestHandler:
    | ((method: string, params: unknown, signal: AbortSignal) => Promise<unknown>)
    | undefined
  closed = false
  failResume = false
  startModel = "gpt-5.2-codex"
  listedThreads: Array<Record<string, unknown>> = []
  threadName: string | null = null
  threadPreview = ""
  goal:
    | {
        createdAt: number
        objective: string
        status: string
        threadId: string
        timeUsedSeconds: number
        tokenBudget: number | null
        tokensUsed: number
        updatedAt: number
      }
    | undefined

  async request<T>(method: string, params?: unknown): Promise<T> {
    this.requests.push({ method, params })
    switch (method) {
      case "initialize":
        return {} as T
      case "thread/start":
        return { model: this.startModel, thread: { id: "thread-new" } } as T
      case "thread/resume":
        if (this.failResume) {
          throw new Error("thread not found")
        }
        return { model: this.startModel, thread: { id: "thread-resumed" } } as T
      case "thread/list":
        return { data: this.listedThreads, nextCursor: null } as T
      case "thread/read":
        return {
          thread: {
            id: "thread-new",
            name: this.threadName,
            preview: this.threadPreview
          }
        } as T
      case "turn/start":
        return { turn: { id: "turn-1", status: "inProgress" } } as T
      case "turn/interrupt":
        return {} as T
      case "thread/goal/set": {
        const update = params as {
          objective?: string
          status?: string
          tokenBudget?: number | null
        }
        this.goal = {
          createdAt: this.goal?.createdAt ?? 1_700_000_000,
          objective: update.objective ?? this.goal?.objective ?? "existing objective",
          status: update.status ?? this.goal?.status ?? "active",
          threadId: "thread-new",
          timeUsedSeconds: this.goal?.timeUsedSeconds ?? 0,
          tokenBudget:
            "tokenBudget" in update ? update.tokenBudget! : (this.goal?.tokenBudget ?? null),
          tokensUsed: this.goal?.tokensUsed ?? 0,
          updatedAt: 1_700_000_100
        }
        return { goal: this.goal } as T
      }
      case "thread/goal/clear": {
        const cleared = this.goal !== undefined
        this.goal = undefined
        return { cleared } as T
      }
      case "model/list":
        return {
          data: [
            {
              defaultReasoningEffort: "medium",
              description: "",
              displayName: "GPT-5.2 Codex",
              hidden: false,
              id: "gpt-5.2-codex",
              model: "gpt-5.2-codex",
              serviceTiers: [
                { description: "Faster processing", id: "priority", name: "Priority" }
              ],
              supportedReasoningEfforts: [
                { description: "", reasoningEffort: "low" },
                { description: "", reasoningEffort: "medium" },
                { description: "", reasoningEffort: "xhigh" }
              ]
            },
            {
              defaultReasoningEffort: "high",
              description: "",
              displayName: "GPT-5.5",
              hidden: false,
              id: "gpt-5.5",
              model: "gpt-5.5",
              supportedReasoningEfforts: [
                { description: "", reasoningEffort: "medium" },
                { description: "", reasoningEffort: "high" }
              ]
            },
            {
              displayName: "Hidden model",
              hidden: true,
              id: "secret",
              model: "secret"
            }
          ]
        } as T
      default:
        throw new Error(`Unexpected request: ${method}`)
    }
  }

  notify(method: string, params?: unknown): void {
    this.notifications.push({ method, params })
  }

  onNotification(handler: (method: string, params: unknown) => void): void {
    this.notificationHandler = handler
  }

  onRequest(
    handler: (method: string, params: unknown, signal: AbortSignal) => Promise<unknown>
  ): void {
    this.requestHandler = handler
  }

  onClose(): void {}

  close(): void {
    this.closed = true
  }

  emit(method: string, params: unknown): void {
    this.notificationHandler?.(method, params)
  }

  async serverRequest(method: string, params: unknown, signal?: AbortSignal): Promise<unknown> {
    if (this.requestHandler === undefined) throw new Error("no request handler")
    return this.requestHandler(method, params, signal ?? new AbortController().signal)
  }
}

/// The shape the Codex desktop app writes into `~/.codex/config.toml`: its
/// bundled automation servers are defined with real transports.
export const DEFAULT_CODEX_CONFIG_TOML = `
[mcp_servers.node_repl]
command = "/Applications/ChatGPT.app/node_repl"

[mcp_servers."computer-use"]
command = "/Applications/ChatGPT.app/computer-use"

[mcp_servers.cua_repl]
command = "/Applications/ChatGPT.app/cua_repl"
`

export const setup = async (
  options: {
    failResume?: boolean
    resume?: string
    startModel?: string
    toolGateway?: ToolGatewayConfig
    /// `null` models a machine with no codex config.toml at all.
    codexConfigToml?: string | null
  } = {}
) => {
  const client = new FakeCodexClient()
  client.failResume = options.failResume ?? false
  client.startModel = options.startModel ?? "gpt-5.2-codex"
  const spawns: Array<CodexSpawnRequest> = []
  const provider = makeCodexProvider(environment, {
    connector: async (request) => {
      spawns.push(request)
      return client
    },
    configFileReader: () =>
      options.codexConfigToml === null
        ? undefined
        : (options.codexConfigToml ?? DEFAULT_CODEX_CONFIG_TOML)
  })
  const events: Array<RuntimeEvent> = []
  const emit = async (event: RuntimeEvent): Promise<void> => {
    events.push(event)
  }
  const created =
    options.resume === undefined
      ? await run(
          provider.createSession(definition, "/tmp/project", emit, undefined, options.toolGateway)
        )
      : undefined
  const loaded =
    options.resume === undefined
      ? undefined
      : await run(
          provider.loadSession(
            definition,
            options.resume,
            "/tmp/project",
            emit,
            undefined,
            options.toolGateway
          )
        )
  return { client, created, events, loaded, provider, spawns }
}

export const UNIFIED_DIFF = [
  "--- a/release.yml",
  "+++ b/release.yml",
  "@@ -1,3 +1,4 @@",
  " keep",
  "-old",
  "+new",
  "+extra"
].join("\n")
