import { randomUUID } from "node:crypto"

import {
  type Cancel,
  type Clock,
  isoTime,
  systemClock,
  createEventStreams,
  type EventOccurrence,
  type EventStreams,
  type StreamOpening,
  eventTypeNamed,
  registerEventTypes,
  eventsExtension,
  panesExtension,
  skillsExtension,
  uiExtension,
  eventsPollRequest,
  eventsStreamRequest,
  registerResources,
  registerSkills,
  skillCatalog,
  errorResult,
  structuredResult
} from "@codevisor/plugin-kit"
import { Server } from "@modelcontextprotocol/sdk/server/index.js"
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { z } from "zod"

import { createEventBuffer, type EventBuffer, type Replay } from "./event-buffer.js"
import { eventsPage } from "./events-page.js"
import {
  counterEvent,
  eventsPageUri,
  pingDefaults,
  pingEvent,
  testEventTools,
  testEventTypes
} from "./test-events-catalog.js"
import { testEventsSkill } from "./test-events-skill.js"

export interface TestEventsServerOptions {
  clock?: Clock
  bootId?: string
  capacity?: number
  intervalMs?: number
}

export const testEventsDefaults = {
  capacity: 200,
  maxPollEvents: 50,
  nextPollMs: 2_000,
  recentLimit: 20
} as const

export const testEventsCapabilities = {
  tools: {},
  resources: {},
  extensions: {
    [eventsExtension]: { listChanged: false },
    [skillsExtension]: {},
    [uiExtension]: {},
    [panesExtension]: {
      panes: [{ type: "events", title: "Test events", resourceUri: eventsPageUri }]
    }
  }
}

export const testEventsOptionsFromEnv = (env: NodeJS.ProcessEnv): TestEventsServerOptions => {
  const intervalMs = Number(env[intervalEnvKey])
  if (!isPositiveInteger(intervalMs)) return {}

  return { intervalMs }
}

export const createTestEventsServer = (options: TestEventsServerOptions = {}): Server => {
  const clock = options.clock ?? systemClock
  const buffer = createEventBuffer(
    options.bootId ?? randomUUID(),
    options.capacity ?? testEventsDefaults.capacity
  )
  const streams = createEventStreams({ clock, heartbeatCursor: () => buffer.head() })
  const publisher = eventPublisher(clock, buffer, (occurrence) =>
    streams.publish(occurrence, (stream) => stream.name === occurrence.name)
  )
  const server = new Server(
    { name: "test-events", version: "1.0.0" },
    { capabilities: testEventsCapabilities }
  )

  registerEvents(server, buffer, clock, streams)
  registerTools(server, publisher, buffer)
  registerResources(server, [eventsPage, ...skills.resources])
  registerSkills(server, skills)

  // oxlint-disable-next-line unicorn/prefer-add-event-listener
  server.onclose = startCounterTimer(clock, options.intervalMs, publisher)
  return server
}

interface EventPublisher {
  publish(name: string, data: Record<string, unknown>, eventId?: string): EventOccurrence
  nextCount(): number
}

const eventPublisher = (
  clock: Clock,
  buffer: EventBuffer,
  deliver: (occurrence: EventOccurrence) => void
): EventPublisher => {
  let emitted = 0
  return {
    publish: (name, data, eventId) => {
      emitted += 1
      const now = clock.now()
      const occurrence = buffer.append(
        { eventId: eventId ?? `evt-${emitted}`, name, timestamp: isoTime(now), data },
        now
      )
      deliver(occurrence)
      return occurrence
    },
    nextCount: () => emitted + 1
  }
}

const registerEvents = (
  server: Server,
  buffer: EventBuffer,
  clock: Clock,
  streams: EventStreams
): void => {
  registerEventTypes(server, testEventTypes)
  server.setRequestHandler(eventsPollRequest, (request) => {
    eventTypeNamed(testEventTypes, request.params.name)
    const maxEvents = Math.min(request.params.maxEvents ?? maxPollEvents, maxPollEvents)
    const replay = buffer.replay({ ...request.params, maxEvents }, clock.now())
    return { resultType: "complete", ...pollResult(replay) }
  })
  server.setRequestHandler(eventsStreamRequest, (request, extra) => {
    eventTypeNamed(testEventTypes, request.params.name)
    const replay = buffer.replay({ ...request.params, maxEvents: Infinity }, clock.now())
    return streams.open(streamOpening(request.params.name, replay), extra)
  })
}

const maxPollEvents = testEventsDefaults.maxPollEvents

const streamOpening = (name: string, replay: Replay): StreamOpening => ({
  name,
  accountId: undefined,
  position: { cursor: replay.start, truncated: replay.truncated },
  backlog: replay.events
})

const pollResult = (replay: Replay) => ({
  events: replay.events,
  cursor: replay.cursor,
  truncated: replay.truncated,
  hasMore: replay.hasMore,
  nextPollMs: testEventsDefaults.nextPollMs
})

const registerTools = (server: Server, publisher: EventPublisher, buffer: EventBuffer): void => {
  server.setRequestHandler(ListToolsRequestSchema, () => ({ tools: [...testEventTools] }))
  server.setRequestHandler(CallToolRequestSchema, (request) =>
    runTool(request.params.name, request.params.arguments ?? {}, publisher, buffer)
  )
}

const runTool = (
  name: string,
  args: Record<string, unknown>,
  publisher: EventPublisher,
  buffer: EventBuffer
): CallToolResult => {
  if (name === "emit") return emit(args, publisher)
  if (name === "list_recent" || name === "show_events") return listRecent(args, buffer)

  return errorResult(`Unknown tool: ${name}`)
}

const emit = (args: Record<string, unknown>, publisher: EventPublisher): CallToolResult => {
  const parsed = emitArguments.safeParse(args)
  if (!parsed.success) return errorResult(z.prettifyError(parsed.error))

  const { name, data, eventId } = parsed.data
  const defaults = name === pingEvent ? pingDefaults : { value: publisher.nextCount() }
  return structuredResult({ event: publisher.publish(name, { ...defaults, ...data }, eventId) })
}

const listRecent = (args: Record<string, unknown>, buffer: EventBuffer): CallToolResult => {
  const parsed = listArguments.safeParse(args)
  if (!parsed.success) return errorResult(z.prettifyError(parsed.error))

  return structuredResult({ events: buffer.recent(parsed.data.limit) })
}

const startCounterTimer = (
  clock: Clock,
  intervalMs: number | undefined,
  publisher: EventPublisher
): Cancel => {
  if (intervalMs === undefined) return () => undefined

  return clock.every(intervalMs, () =>
    publisher.publish(counterEvent, { value: publisher.nextCount() })
  )
}

const isPositiveInteger = (value: number): boolean => Number.isInteger(value) && value > 0

const intervalEnvKey = "CODEVISOR_TEST_EVENTS_INTERVAL_MS"

const skills = skillCatalog([testEventsSkill])

const emitArguments = z.object({
  name: z.enum([pingEvent, counterEvent]),
  data: z.record(z.string(), z.unknown()).optional(),
  eventId: z.string().min(1).optional()
})

const listArguments = z.object({
  limit: z.number().int().min(1).max(200).default(testEventsDefaults.recentLimit)
})
