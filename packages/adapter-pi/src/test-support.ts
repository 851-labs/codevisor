import type { HarnessDefinition, ProviderEnvironment, RuntimeEvent } from "@codevisor/agent-runtime"
import { isRecord } from "@codevisor/api"
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
  envFor: () => Promise.resolve(environment.env),
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

export class FakePiClient implements PiClient {
  readonly commands: Array<{ type: string; fields: Record<string, unknown> }> = []
  readonly responses: Array<Record<string, unknown>> = []
  closed = false
  replies: Record<string, unknown> = {
    get_state: { sessionId: "pi-1", model: codex, thinkingLevel: "medium" },
    get_available_models: { models: [codex] },
    get_available_thinking_levels: { levels: ["low", "medium", "high"] },
    get_commands: { commands: [] },
    prompt: { disposition: "started" },
    abort: null,
    set_thinking_level: null,
    set_model: claude
  }
  private eventHandler: ((event: Record<string, unknown>) => void) | undefined
  private closeHandler: ((error: Error) => void) | undefined

  private readonly commandWaiters: Array<{ type: string; resolve: () => void }> = []

  nextCommand(type: string): Promise<void> {
    return new Promise((resolve) => {
      this.commandWaiters.push({ type, resolve })
    })
  }

  command(type: string, fields: Record<string, unknown> = {}): Promise<unknown> {
    this.commands.push({ type, fields })
    const index = this.commandWaiters.findIndex((waiter) => waiter.type === type)
    if (index !== -1) this.commandWaiters.splice(index, 1)[0]!.resolve()
    const reply = this.replies[type]
    return reply instanceof Error ? Promise.reject(reply) : Promise.resolve(reply)
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

export const recordPayload = (event: Pick<RuntimeEvent, "payload">): Record<string, unknown> => {
  if (!isRecord(event.payload)) throw new Error("Expected a record payload")
  return event.payload
}

export const payloads = (events: ReadonlyArray<Pick<RuntimeEvent, "payload">>) =>
  events.map(recordPayload)
