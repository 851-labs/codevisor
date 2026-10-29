import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { McpServer, PluginCapabilities } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { onTestFinished } from "vitest"

import { fixtureChanged } from "../../changes-test-support.js"
import type { PendingSessionEvent } from "../../routes/session-event-outbox.js"
import { makeServices, run, tempDirs, waitFor } from "../../test-support.js"
import type { EventConnection, PluginEventConnections } from "./plugin-event-connections.js"
import type { PluginEventOutbox } from "./plugin-event-delivery.js"
import type { CloudInboxApi } from "./plugin-event-ingress.js"
import type { EventTimers } from "./plugin-event-sources.js"
import { makePluginEvents, type PluginEvents, type PluginEventsDeps } from "./plugin-events.js"

export type RequestHandler = (
  params: Record<string, unknown>
) => Promise<Record<string, unknown>> | Record<string, unknown>

export interface RecordedRequest {
  readonly serverId: string
  readonly method: string
  readonly params: Record<string, unknown>
  readonly accountId?: string
}

export interface OpenedStream {
  readonly serverId: string
  readonly params: Record<string, unknown>
  readonly accountId?: string
  readonly signal: AbortSignal
  readonly send: (method: string, params: Record<string, unknown>) => void
  readonly end: () => void
}

export interface FakePlugin {
  readonly server: McpServer
  readonly handlers: Record<string, RequestHandler>
}

export const pingPayloadSchema = {
  type: "object",
  properties: {
    message: { type: "string" },
    level: { type: "string", enum: ["info", "warn", "error"] },
    count: { type: "integer" }
  },
  required: ["message", "level", "count"]
}

export const capabilitiesWith = (
  overrides: Partial<PluginCapabilities> = {}
): PluginCapabilities => ({
  tools: [],
  events: [{ name: "ping" }],
  skills: [],
  panes: [],
  ingress: [],
  ...overrides
})

export interface PluginRowOverrides {
  readonly enabled?: boolean
  readonly capabilities?: PluginCapabilities | null
  readonly catalogId?: string
  readonly command?: string
  readonly authType?: McpServer["authType"]
  readonly connectionState?: McpServer["connectionState"]
}

export const savePluginRow = (
  db: CodevisorDatabaseService,
  name: string,
  overrides: PluginRowOverrides = {}
): Promise<McpServer> =>
  run(
    db.saveMcpServer({
      name,
      transport: "stdio",
      command: overrides.command ?? "plugin",
      args: [],
      enabled: overrides.enabled ?? true,
      authType: overrides.authType ?? "none",
      connectionState: overrides.connectionState ?? "connected",
      toolCount: 0,
      ...capabilitiesField(overrides.capabilities),
      ...(overrides.catalogId === undefined ? {} : { catalogId: overrides.catalogId })
    })
  )

const capabilitiesField = (capabilities: PluginCapabilities | null | undefined) => {
  if (capabilities === null) return {}
  return { capabilities: capabilities ?? capabilitiesWith() }
}

export const eventList =
  (...events: ReadonlyArray<Record<string, unknown>>): RequestHandler =>
  () => ({ events })

export const pingType = (overrides: Record<string, unknown> = {}): Record<string, unknown> => ({
  name: "ping",
  description: "A ping",
  delivery: ["poll"],
  inputSchema: { type: "object" },
  payloadSchema: pingPayloadSchema,
  ...overrides
})

export const fakeConnections = () => {
  const plugins = new Map<string, FakePlugin>()
  const requests: Array<RecordedRequest> = []
  const streams: Array<OpenedStream> = []
  const listeners = new Set<(serverId: string, state: "connected" | "closed") => void>()

  const handle = async (
    serverId: string,
    method: string,
    params: Record<string, unknown>,
    accountId: string | undefined
  ) => {
    requests.push({ serverId, method, params, ...(accountId === undefined ? {} : { accountId }) })
    fixtureChanged()
    const handler = plugins.get(serverId)?.handlers[method]
    if (handler === undefined) throw new Error(`${serverId} has no ${method} handler`)
    return handler(params)
  }

  const connectionOf = (server: McpServer): EventConnection => ({
    serverId: server.id,
    name: server.name,
    request: (method, params, options) => handle(server.id, method, params, options?.accountId),
    openStream: (_method, params, options) =>
      new Promise((resolve, reject) => {
        options.signal.addEventListener(
          "abort",
          () => {
            reject(new Error("stream aborted"))
            fixtureChanged()
          },
          { once: true }
        )
        streams.push({
          serverId: server.id,
          params,
          ...(options.accountId === undefined ? {} : { accountId: options.accountId }),
          signal: options.signal,
          send: options.onNotification,
          end: () => resolve({})
        })
        fixtureChanged()
      }),
    notify: async () => undefined,
    onNotification: () => () => undefined
  })

  const connections: PluginEventConnections = {
    servers: async () => [...plugins.values()].map((plugin) => plugin.server),
    connection: async (serverId) => {
      const plugin = plugins.get(serverId)
      if (plugin === undefined) throw new Error(`No connection to ${serverId}`)
      return connectionOf(plugin.server)
    },
    subscribeConnections: (listener) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    }
  }

  return {
    connections,
    requests,
    streams,
    add: (server: McpServer, handlers: Record<string, RequestHandler>): FakePlugin => {
      const plugin = { server, handlers }
      plugins.set(server.id, plugin)
      return plugin
    },
    remove: (serverId: string) => {
      plugins.delete(serverId)
    },
    reconnected: (serverId: string) => {
      for (const listener of listeners) listener(serverId, "connected")
    },
    requestsOf: (method: string) => requests.filter((request) => request.method === method)
  }
}

export type FakeConnections = ReturnType<typeof fakeConnections>

export interface PendingSleep {
  readonly ms: number
  readonly signal: AbortSignal
  readonly wake: () => void
}

export const manualTimers = () => {
  const sleeps: Array<PendingSleep> = []
  const timers: EventTimers = {
    sleep: (ms, signal) =>
      new Promise((resolve, reject) => {
        if (signal.aborted) return reject(new Error("aborted"))
        signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true })
        sleeps.push({ ms, signal, wake: resolve })
        fixtureChanged()
      })
  }
  const live = () => sleeps.filter((sleep) => !sleep.signal.aborted)
  return {
    timers,
    sleeps,
    delays: () => sleeps.map((sleep) => sleep.ms),
    nextSleep: async (count: number): Promise<PendingSleep> => {
      await waitFor(() => sleeps.length >= count)
      return sleeps[count - 1]!
    },
    live
  }
}

export const recordingOutbox = () => {
  const delivered: Array<{ readonly subscriberId: string; readonly event: PendingSessionEvent }> =
    []
  let failures = 0
  const outbox: PluginEventOutbox = {
    deliver: async (subscriberId, event) => {
      if (failures > 0) {
        failures -= 1
        throw new Error("outbox unavailable")
      }
      delivered.push({ subscriberId, event })
      fixtureChanged()
    }
  }
  return {
    outbox,
    delivered,
    texts: () => delivered.map((entry) => entry.event.message.text),
    failNext: () => {
      failures += 1
    }
  }
}

export const eventsFixture = async (overrides: Partial<PluginEventsDeps> = {}) => {
  const { services } = await makeServices("server-a")
  const folder = mkdtempSync(join(tmpdir(), "codevisor-plugin-events-"))
  tempDirs.push(folder)
  const project = await run(services.db.createProject({ folderPath: folder }))
  const session = await run(
    services.db.createSession({ projectId: project.id, harnessId: "codex" })
  )
  const fake = fakeConnections()
  const clock = manualTimers()
  const outbox = recordingOutbox()
  const deps: PluginEventsDeps = {
    db: services.db,
    connections: fake.connections,
    outbox: outbox.outbox,
    now: Date.now,
    timers: clock.timers,
    ...overrides
  }
  const engine = (extra: Partial<PluginEventsDeps> = {}): PluginEvents => {
    const events = makePluginEvents({ ...deps, ...extra })
    onTestFinished(() => events.close())
    return events
  }
  return { services, db: services.db, project, session, fake, clock, outbox, engine }
}

export type EventsFixture = Awaited<ReturnType<typeof eventsFixture>>

export const pingPlugin = async (
  fixture: EventsFixture,
  name = "Pinger",
  handlers: Record<string, RequestHandler> = {}
): Promise<McpServer> => {
  const server = await savePluginRow(fixture.db, name)
  fixture.fake.add(server, { "events/list": eventList(pingType()), ...handlers })
  return server
}

export const ping = (eventId: string, data: Record<string, unknown> = {}) => ({
  eventId,
  name: "ping",
  timestamp: "2026-10-27T09:00:00.000Z",
  data: { message: "hello", level: "info", count: 1, ...data }
})

export const fakeInboxes = () => {
  const calls: Array<string> = []
  let unsubscribeFails = false
  const inboxes: CloudInboxApi = {
    ensure: async (target) => {
      calls.push(`ensure ${target.plugin} ${target.accountId} ${target.ingress}`)
      const id = `${target.accountId}-${target.ingress}`
      return { id, url: `https://inbox.example/i/${id}` }
    },
    subscribe: async (inboxId) => {
      calls.push(`subscribe ${inboxId}`)
    },
    unsubscribe: async (inboxId) => {
      calls.push(`unsubscribe ${inboxId}`)
      fixtureChanged()
      if (unsubscribeFails) throw new Error("cloud unavailable")
    },
    route: async (inboxId, route, key) => {
      calls.push(`route ${inboxId} ${route} ${key}`)
      return { topic: `projects/test/topics/${route}` }
    },
    remove: async (inboxId) => {
      calls.push(`remove ${inboxId}`)
    }
  }
  return {
    inboxes,
    calls,
    failUnsubscribes: () => {
      unsubscribeFails = true
    }
  }
}
