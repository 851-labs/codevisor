import type { HarnessDefinition, ProviderEnvironment, RuntimeEvent } from "@codevisor/agent-runtime"
import { Effect } from "effect"

import type { PiClient, PiSpawnRequest } from "./client.js"
import { makePiProvider, type PiProviderConfig } from "./provider.js"

export const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

export const definition: HarnessDefinition = {
  detectBinaries: ["pi"],
  id: "pi",
  name: "Pi",
  provider: "pi",
  symbolName: "function"
}

export const environment: ProviderEnvironment = {
  env: { PATH: "/bin" },
  executableExists: (name) => name === "pi",
  locateExecutable: (name) => (name === "pi" ? "/bin/pi" : undefined)
}

export const codex = {
  id: "gpt-6",
  name: "GPT-6",
  provider: "openai-codex",
  contextWindow: 272_000
}
export const claude = {
  id: "sonnet",
  name: "Sonnet",
  provider: "anthropic",
  contextWindow: 200_000
}

/// A scripted Pi: answers commands from `replies` (data, or an Error to
/// fail), records what it was sent, and lets a test push events.
export class FakePiClient implements PiClient {
  readonly commands: Array<{ type: string; fields: Record<string, unknown> }> = []
  readonly responses: Array<Record<string, unknown>> = []
  closed = false
  replies: Record<string, unknown> = {
    get_state: { sessionId: "pi-1", model: codex, thinkingLevel: "medium" },
    get_available_models: { models: [codex] },
    get_available_thinking_levels: { levels: ["low", "medium", "high"] },
    prompt: { disposition: "started" },
    abort: null,
    set_thinking_level: null,
    set_model: claude
  }
  private eventHandler: ((event: Record<string, unknown>) => void) | undefined
  private closeHandler: ((error: Error) => void) | undefined

  command<T>(type: string, fields: Record<string, unknown> = {}): Promise<T> {
    this.commands.push({ type, fields })
    const reply = this.replies[type]
    return reply instanceof Error ? Promise.reject(reply) : Promise.resolve(reply as T)
  }

  onEvent(handler: (event: Record<string, unknown>) => void): void {
    this.eventHandler = handler
  }

  respond(response: Record<string, unknown>): void {
    this.responses.push(response)
  }

  onClose(handler: (error: Error) => void): void {
    this.closeHandler = handler
  }

  close(): void {
    this.closed = true
  }

  emit(...events: ReadonlyArray<Record<string, unknown>>): void {
    for (const event of events) this.eventHandler?.(event)
  }

  crash(error: Error): void {
    this.closeHandler?.(error)
  }
}

export const setup = (config: PiProviderConfig = {}) => {
  const client = new FakePiClient()
  const spawned: Array<PiSpawnRequest> = []
  const events: Array<RuntimeEvent> = []
  const provider = makePiProvider(environment, {
    connector: async (request) => {
      spawned.push(request)
      return client
    },
    writeExtension: async (name) => `/tmp/${name}.ts`,
    ...config
  })
  const emit = async (event: RuntimeEvent) => {
    events.push(event)
  }
  return { client, spawned, events, provider, emit }
}

/// The payloads of emitted events, for compact assertions.
export const payloads = (events: ReadonlyArray<RuntimeEvent>) =>
  events.map((event) => event.payload as Record<string, unknown>)
