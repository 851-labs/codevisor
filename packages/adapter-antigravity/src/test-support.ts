import type { HarnessDefinition, ProviderEnvironment, RuntimeEvent } from "@codevisor/agent-runtime"
import { Effect } from "effect"

import type { AgyTerminal, AgyTerminalSpawner } from "./auth.js"
import type { AgyConnector, AgyProcess, AgyRunner, AgySpawnRequest } from "./client.js"

export const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

export const definition: HarnessDefinition = {
  detectBinaries: ["agy"],
  id: "antigravity",
  name: "Antigravity",
  provider: "antigravity",
  symbolName: "atom"
}

export const environment: ProviderEnvironment = {
  env: { PATH: "/bin", HOME: "/home/me" },
  executableExists: (name) => name === "agy",
  locateExecutable: (name) => (name === "agy" ? "/bin/agy" : undefined)
}

export const CONVERSATION = "c-1"

/// `agy models` as 1.3.4 prints it: a status line, then tab-separated rows.
export const MODELS_OUTPUT = [
  "Fetching available models...",
  "gemini-4-argon-high\tGemini 4 Argon (High)",
  "gemini-4-argon-medium\tGemini 4 Argon (Medium)",
  "gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)",
  "gpt-oss-120b\tGPT-OSS 120B"
].join("\n")

/// A scripted `agy` headless process: records what it was sent and lets a
/// test push events or end it. By default it opens `conversation` at once.
export class FakeAgyProcess implements AgyProcess {
  readonly sent: Array<Record<string, unknown>> = []
  interrupted = 0
  closed = false
  private eventHandler: ((event: Record<string, unknown>) => void) | undefined
  private readonly exitHandlers: Array<(error: Error) => void> = []

  constructor(
    readonly request: AgySpawnRequest,
    /// Runs once the chat has wired its handlers (its exit handler last).
    private readonly opens: (process: FakeAgyProcess) => void = () => undefined
  ) {}

  private readonly sendWaiters: Array<{ count: number; resolve: () => void }> = []

  send(message: Record<string, unknown>) {
    this.sent.push(message)
    for (const waiter of this.sendWaiters.filter((entry) => this.sent.length >= entry.count))
      waiter.resolve()
  }
  /// Settles once the chat has sent `count` lines.
  sends(count = 1): Promise<void> {
    if (this.sent.length >= count) return Promise.resolve()
    return new Promise((resolve) => this.sendWaiters.push({ count, resolve }))
  }
  onEvent(handler: (event: Record<string, unknown>) => void) {
    this.eventHandler = handler
  }
  onExit(handler: (error: Error) => void) {
    this.exitHandlers.push(handler)
    if (this.exitHandlers.length === 1) this.opens(this)
  }
  interrupt() {
    this.interrupted += 1
  }
  close() {
    this.closed = true
  }

  emit(event: Record<string, unknown>) {
    this.eventHandler?.(event)
  }
  init(conversationId = CONVERSATION) {
    this.emit({ event: "init", conversation_id: conversationId, init: { cwd: "/repo" } })
  }
  step(step: Record<string, unknown>) {
    this.emit({
      event: "step_update",
      step_update: { conversation_id: CONVERSATION, state: "DONE", ...step }
    })
  }
  result(result: Record<string, unknown> = {}) {
    this.emit({
      event: "result",
      result: { conversation_id: CONVERSATION, status: "SUCCESS", response: "", ...result }
    })
  }
  exit(message = "agy exited") {
    for (const handler of this.exitHandlers) handler(new Error(message))
  }
}

/// Hands out fake processes in order; `opens` decides what each does as it
/// starts (default: open the conversation).
export const fakeConnector = (
  opens: (process: FakeAgyProcess, index: number) => void = (process) => process.init()
) => {
  const processes: Array<FakeAgyProcess> = []
  const waiters: Array<{ count: number; resolve: (process: FakeAgyProcess) => void }> = []
  const connector: AgyConnector = async (request) => {
    const index = processes.length
    const process = new FakeAgyProcess(request, (wired) => opens(wired, index))
    processes.push(process)
    for (const waiter of waiters.filter((entry) => processes.length >= entry.count))
      waiter.resolve(processes[waiter.count - 1]!)
    return process
  }
  /// Settles with the `count`th process once it has been spawned.
  const spawned = (count: number): Promise<FakeAgyProcess> =>
    processes.length >= count
      ? Promise.resolve(processes[count - 1]!)
      : new Promise((resolve) => waiters.push({ count, resolve }))
  return { connector, processes, spawned }
}

/// Answers one-shot commands by their arguments; records each call.
export const fakeRunner = (
  answers: Record<string, { code?: number; stdout?: string; stderr?: string } | Error> = {}
) => {
  const calls: Array<Parameters<AgyRunner>[0]> = []
  const runner: AgyRunner = async (request) => {
    calls.push(request)
    const key = request.args.filter((arg) => !arg.startsWith("--gemini_dir")).join(" ")
    const answer = answers[key] ?? (key === "--version" ? { stdout: "1.3.4\n" } : undefined)
    if (answer instanceof Error) throw answer
    if (answer === undefined) return { code: 0, stdout: MODELS_OUTPUT, stderr: "" }
    return { code: answer.code ?? 0, stdout: answer.stdout ?? "", stderr: answer.stderr ?? "" }
  }
  return { runner, calls }
}

export const recorder = () => {
  const events: Array<RuntimeEvent> = []
  return {
    events,
    emit: (event: RuntimeEvent) => {
      events.push(event)
      return Promise.resolve()
    },
    outputs: () =>
      events
        .filter((event) => event.kind === "session.output")
        .map((event) => event.payload as Record<string, unknown>),
    updates: () =>
      events
        .filter((event) => event.kind === "session.updated")
        .map((event) => event.payload as Record<string, unknown>)
  }
}

/// A terminal agy's TUI "draws" into: the test writes the screen and reads
/// back what the login typed.
export class FakeTerminal implements AgyTerminal {
  readonly written: Array<string> = []
  killed = false
  private dataHandler: ((data: string) => void) | undefined
  private exitHandler: ((code: number) => void) | undefined

  write(data: string) {
    this.written.push(data)
  }
  onData(handler: (data: string) => void) {
    this.dataHandler = handler
  }
  onExit(handler: (code: number) => void) {
    this.exitHandler = handler
  }
  kill() {
    this.killed = true
  }
  draw(data: string) {
    this.dataHandler?.(data)
  }
  exit(code = 0) {
    this.exitHandler?.(code)
  }
}

export const fakeTerminalSpawner = () => {
  const terminal = new FakeTerminal()
  const requests: Array<Parameters<AgyTerminalSpawner>[0]> = []
  const spawned = Promise.withResolvers<void>()
  const spawn: AgyTerminalSpawner = async (request) => {
    requests.push(request)
    spawned.resolve()
    return terminal
  }
  /// Settles once the login has started its terminal and wired it.
  const ready = async () => {
    await spawned.promise
    await Promise.resolve()
  }
  return { spawn, terminal, requests, ready }
}
