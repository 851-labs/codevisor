import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { Effect } from "effect"

import type { Catalog } from "./catalog.js"
import { openServerSession, type OpenCodeSessionInfo } from "./server-session.js"
import { event, makeFakeServer, makeSink, payload, type RecordedRequest } from "./test-support.js"

export const ROOT = "ses_root"
export const PATH = `/api/session/${ROOT}`

export const catalog: Catalog = {
  models: [
    { providerID: "openrouter", id: "m1", name: "M1", variants: ["low", "high"], context: 1000 },
    { providerID: "opencode", id: "m2", name: "M2", variants: [] }
  ],
  defaultModel: { providerID: "openrouter", id: "m1" },
  modes: [
    { id: "build", name: "Build" },
    { id: "plan", name: "Plan" }
  ],
  defaultModeID: "build",
  commands: ["review"],
  skills: { invocationPrefix: "/", skills: [] }
}

export const isPrompt = (id: string) => (request: RecordedRequest) =>
  request.path === `${PATH}/prompt` && request.body?.id === id

export const setup = (
  options: {
    readonly info?: Partial<OpenCodeSessionInfo>
    readonly respond?: (request: RecordedRequest) => unknown
    readonly reloadCatalog?: () => Promise<Catalog>
    readonly beforeTurn?: () => Promise<void>
  } = {}
) => {
  const fake = makeFakeServer(
    options.respond ??
      ((request) => (request.path === PATH ? { data: { id: ROOT, cost: 0.25 } } : undefined))
  )
  const sink = makeSink()
  let released = 0
  let ids = 0
  const session = openServerSession({
    server: fake.server,
    info: { id: ROOT, ...options.info },
    cwd: "/work",
    events: fake.queue.iterator,
    abort: () => fake.queue.fail(new Error("aborted")),
    catalog,
    reloadCatalog: options.reloadCatalog ?? (async () => catalog),
    emit: sink.emit,
    harnessName: "OpenCode",
    ...(options.beforeTurn === undefined
      ? {}
      : { account: { id: "a", profileKind: "managed" as const, beforeTurn: options.beforeTurn } }),
    release: () => {
      released += 1
    },
    newMessageID: () => `msg_${++ids}`,
    readable: async () => true,
    readText: async () => "after\n"
  })
  return { ...fake, ...sink, ...session, released: () => released }
}

export const run = Effect.runPromise
export const delivered = (inboxID: string) =>
  event("session.inbox.delivered", { sessionID: ROOT, inboxID })
export const text = (delta: string) =>
  event("session.text.delta", { sessionID: ROOT, assistantMessageID: "msg_a", delta })
export const terminal = (outcome: "succeeded" | "interrupted") =>
  event(`session.execution.${outcome}`, { sessionID: ROOT })
export const turnStates = (events: ReadonlyArray<RuntimeEvent>) =>
  events.flatMap((entry) => {
    const state = payload(entry).turnState
    return typeof state === "string" ? [state] : []
  })
