import type { HarnessDefinition, ProviderEnvironment, RuntimeEvent } from "@codevisor/agent-runtime"
import { Effect } from "effect"

import type { MuseClient, MuseSpawnRequest } from "./client.js"
import { TESTED_SCHEMA_FINGERPRINT, type ModelCatalogEntry } from "./protocol.js"
import { makeMuseProvider, type MuseProviderConfig } from "./provider.js"
import { startMuseChat } from "./session.js"

export const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

export const definition: HarnessDefinition = {
  detectBinaries: ["muse"],
  id: "muse-code",
  name: "Muse Code",
  provider: "muse",
  symbolName: "sparkles"
}

export const environment: ProviderEnvironment = {
  env: { PATH: "/bin", HOME: "/home/me" },
  executableExists: (name) => name === "muse",
  locateExecutable: (name) => (name === "muse" ? "/bin/muse" : undefined)
}

const model = (modelId: string, fields: Partial<ModelCatalogEntry> = {}): ModelCatalogEntry => ({
  modelId,
  displayLabel: modelId,
  providerId: "meta",
  profileId: null,
  contextLimit: null,
  isActive: false,
  isDefault: false,
  ...fields
})

export const spark = model("spark", {
  displayLabel: "Muse Spark",
  isActive: true,
  variants: ["low", "medium", "high"]
})
export const lite = model("lite", { displayLabel: "Muse Lite", variants: ["minimal", "low"] })

export const SESSION = "s-1"

export const session = (fields: Record<string, unknown> = {}) => ({
  sessionId: SESSION,
  workspaceRoot: "/repo",
  modelId: "spark",
  providerId: "meta",
  updatedAt: "2026-10-13T00:00:00Z",
  ...fields
})

type Reply = unknown | Error | ((params: Record<string, unknown>) => unknown)

export class FakeMuseClient implements MuseClient {
  readonly requests: Array<{ method: string; params: Record<string, unknown> }> = []
  readonly notified: Array<string> = []
  closed = false
  replies: Record<string, Reply> = {
    initialize: {
      serverInfo: { name: "muse", version: "1.4.7" },
      schema: { version: 1, fingerprint: TESTED_SCHEMA_FINGERPRINT },
      experimentalApi: true,
      grantedCapabilities: ["sessionMcp"]
    },
    "session/start": { session: session() },
    "session/resume": { session: session() },
    "model/list": { models: [spark, lite] },
    "skill/list": { skills: [] },
    "turn/start": (params: Record<string, unknown>) => ({
      turnId: params.commandId,
      status: "accepted"
    }),
    "turn/interrupt": {},
    "session/setModel": {},
    "session/setReasoningEffort": {},
    "approval/decide": {},
    "userInput/answer": {},
    "userInput/cancel": {},
    "account/read": { state: "accountLogin", label: "me@example.com", credentialRequired: true },
    "account/loginStart": { verificationUrl: "https://meta.ai/device", userCode: "ABCD" },
    "account/loginCancel": { cancelled: true },
    "account/logout": {},
    "session/list": { sessions: [], nextCursor: null },
    "usage/read": {}
  }
  private notificationHandler: ((method: string, params: unknown) => void) | undefined
  private requestHandler: ((method: string, params: unknown) => unknown) | undefined
  private readonly closeHandlers: Array<(error: Error) => void> = []
  private readonly waiters: Array<{ method: string; resolve: () => void }> = []

  nextRequest(method: string): Promise<void> {
    return new Promise((resolve) => this.waiters.push({ method, resolve }))
  }

  request<T>(method: string, params: unknown = {}): Promise<T> {
    const fields = params as Record<string, unknown>
    this.requests.push({ method, params: fields })
    const index = this.waiters.findIndex((waiter) => waiter.method === method)
    if (index !== -1) this.waiters.splice(index, 1)[0]!.resolve()
    const reply = this.replies[method]
    if (reply instanceof Error) return Promise.reject(reply)
    return Promise.resolve((typeof reply === "function" ? reply(fields) : reply) as T)
  }

  sent(method: string): Array<Record<string, unknown>> {
    return this.requests.filter((entry) => entry.method === method).map((entry) => entry.params)
  }

  notify(method: string): void {
    this.notified.push(method)
  }

  onNotification(handler: (method: string, params: unknown) => void): void {
    this.notificationHandler = handler
  }

  onRequest(handler: (method: string, params: unknown) => unknown): void {
    this.requestHandler = handler
  }

  onClose(handler: (error: Error) => void): void {
    this.closeHandlers.push(handler)
  }

  close(): void {
    this.closed = true
  }

  emit(method: string, params: Record<string, unknown> = {}): void {
    this.notificationHandler?.(method, { sessionId: SESSION, ...params })
  }

  serverRequest(method: string, params: Record<string, unknown>): unknown {
    return this.requestHandler?.(method, { sessionId: SESSION, ...params })
  }

  crash(error: Error): void {
    for (const handler of this.closeHandlers) handler(error)
  }
}

export const setup = (config: MuseProviderConfig = {}, client = new FakeMuseClient()) => {
  const spawned: Array<MuseSpawnRequest> = []
  const events: Array<RuntimeEvent> = []
  const provider = makeMuseProvider(environment, {
    connector: async (request) => {
      spawned.push(request)
      return client
    },
    ...config
  })
  const emit = async (event: RuntimeEvent) => {
    events.push(event)
  }
  return { client, spawned, events, provider, emit }
}

export const payloads = (events: ReadonlyArray<RuntimeEvent>) =>
  events.map((event) => event.payload as Record<string, unknown>)

export const startChat = async (
  options: Partial<Parameters<typeof startMuseChat>[2]> = {},
  client = new FakeMuseClient()
) => {
  const events: Array<RuntimeEvent> = []
  const chat = await startMuseChat(client, async (event) => void events.push(event), {
    cwd: "/repo",
    ...options
  })
  return { client, chat, events }
}

export const send = async (
  chat: Awaited<ReturnType<typeof startMuseChat>>,
  client: FakeMuseClient,
  input = "go"
) => {
  const sent = client.nextRequest("turn/start")
  const finished = chat.prompt(input)
  await sent
  return { finished, turnId: client.sent("turn/start").at(-1)!.commandId as string }
}

export const turns = (events: ReadonlyArray<RuntimeEvent>) =>
  payloads(events).filter((payload) => "turnState" in payload)
