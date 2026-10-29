import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js"
import type { Server } from "@modelcontextprotocol/sdk/server/index.js"
import type { Notification } from "@modelcontextprotocol/sdk/types.js"
import { z } from "zod"

import type { Clock } from "./clock.js"
import {
  accountMeta,
  eventsExtension,
  panesExtension,
  skillsExtension,
  subscriptionIdMeta,
  webhooksExtension
} from "./plugin-protocol.js"

export const anyResult = z.object({}).loose()

const toolContent = z.object({ content: z.array(z.object({ text: z.string() })) })

export interface ManualClock extends Clock {
  advance(milliseconds: number): void
  timers(): number
}

export const manualClock = (start = Date.parse("2026-10-27T12:00:00.000Z")): ManualClock => {
  let now = start
  const tasks = new Set<ScheduledTask>()
  return {
    now: () => now,
    every: (intervalMs, run) => {
      const task = { intervalMs, due: now + intervalMs, run }
      tasks.add(task)
      return () => tasks.delete(task)
    },
    advance: (milliseconds) => {
      const target = now + milliseconds
      for (let task = nextDue(tasks, target); task !== undefined; task = nextDue(tasks, target)) {
        now = task.due
        task.due += task.intervalMs
        task.run()
      }
      now = target
    },
    timers: () => tasks.size
  }
}

export interface NotificationInbox {
  received: Array<Notification>
  next(method: string, subscriptionId?: unknown): Promise<Notification>
  forSubscription(subscriptionId: unknown): Array<Notification>
}

export interface ConnectedClient {
  client: Client
  inbox: NotificationInbox
  serverTransport: InMemoryTransport
}

export const connectClient = async (server: Server): Promise<ConnectedClient> => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair()
  const client = new Client({ name: "test-host", version: "1.0.0" })
  const inbox = notificationInbox()
  client.fallbackNotificationHandler = async (notification) => inbox.deliver(notification)
  await server.connect(serverTransport)
  await client.connect(clientTransport)
  return { client, inbox, serverTransport }
}

export interface OpenedStream {
  subscriptionId: unknown
  active: Notification
  closed: Promise<unknown>
}

export const openStream = async (
  connected: ConnectedClient,
  params: Record<string, unknown>,
  signal?: AbortSignal
): Promise<OpenedStream> => {
  const closed = connected.client.request(
    { method: "events/stream", params },
    anyResult,
    signal ? { signal } : {}
  )
  closed.catch(() => undefined)
  const active = await connected.inbox.next("notifications/events/active")
  return { subscriptionId: subscriptionOf(active), active, closed }
}

export const toolText = (result: unknown): string =>
  toolContent
    .parse(result)
    .content.map((part) => part.text)
    .join("")

export const subscriptionOf = (notification: Notification): unknown =>
  notification.params?._meta?.[subscriptionIdMeta]

export const withAccount = (
  id: string,
  fields: Record<string, unknown>
): Record<string, unknown> => ({
  [accountMeta]: { id, label: `Account ${id}`, fields }
})

interface ScheduledTask {
  intervalMs: number
  due: number
  run: () => void
}

const nextDue = (tasks: Set<ScheduledTask>, target: number): ScheduledTask | undefined =>
  [...tasks].filter((task) => task.due <= target).toSorted((left, right) => left.due - right.due)[0]

interface Waiter {
  method: string
  subscriptionId: unknown
  resolve: (notification: Notification) => void
}

const matches = (notification: Notification, method: string, subscriptionId: unknown): boolean =>
  notification.method === method &&
  (subscriptionId === undefined || subscriptionOf(notification) === subscriptionId)

const notificationInbox = (): NotificationInbox & { deliver(notification: Notification): void } => {
  const received: Array<Notification> = []
  const consumed = new Set<Notification>()
  const waiters = new Set<Waiter>()
  const claim = (notification: Notification, waiter: Waiter): void => {
    consumed.add(notification)
    waiters.delete(waiter)
    waiter.resolve(notification)
  }

  return {
    received,
    deliver: (notification) => {
      received.push(notification)
      const waiter = [...waiters].find((candidate) =>
        matches(notification, candidate.method, candidate.subscriptionId)
      )
      if (waiter !== undefined) claim(notification, waiter)
    },
    next: (method, subscriptionId) =>
      new Promise((resolve) => {
        const waiter = { method, subscriptionId, resolve }
        const buffered = received.find(
          (candidate) => !consumed.has(candidate) && matches(candidate, method, subscriptionId)
        )
        if (buffered === undefined) waiters.add(waiter)
        else claim(buffered, waiter)
      }),
    forSubscription: (subscriptionId) =>
      received.filter((candidate) => subscriptionOf(candidate) === subscriptionId)
  }
}

export interface CapabilityDigest {
  tools: Array<{ name: string; app: boolean }>
  events: Array<string>
  skills: Array<{ name: string; description: string }>
  panes: Array<{ type: string; title: string; resourceUri: string }>
  ingress: Array<{ name: string; title?: string | undefined; route?: string | undefined }>
}

export const advertisedCapabilities = (serverJson: unknown): CapabilityDigest => {
  const capabilities = advertisedServer.parse(serverJson)._meta["dev.codevisor/plugin"].capabilities
  return {
    tools: capabilities.tools.map((tool) => ({ name: tool.name, app: tool.app ?? false })),
    events: capabilities.events.map((event) => event.name),
    skills: capabilities.skills,
    panes: capabilities.panes,
    ingress: capabilities.ingress
  }
}

export const servedCapabilities = async (client: Client): Promise<CapabilityDigest> => {
  const extensions = client.getServerCapabilities()?.extensions ?? {}
  const { tools } = await client.listTools()
  return {
    tools: tools.map((tool) => ({ name: tool.name, app: servedApp.safeParse(tool._meta).success })),
    events: await servedEvents(client, eventsExtension in extensions),
    skills: await servedSkills(client, skillsExtension in extensions),
    panes: panesSetting.parse(extensions[panesExtension] ?? { panes: [] }).panes,
    ingress: ingressSetting.parse(extensions[webhooksExtension] ?? { ingress: [] }).ingress
  }
}

const servedEvents = async (client: Client, declared: boolean): Promise<Array<string>> => {
  if (!declared) return []

  const listed = await client.request({ method: "events/list" }, eventList)
  return listed.events.map((event) => event.name)
}

const servedSkills = async (
  client: Client,
  declared: boolean
): Promise<CapabilityDigest["skills"]> => {
  if (!declared) return []

  const listed = await client.request({ method: "skills/list" }, skillList)
  return listed.skills.map((skill) => skill.frontmatter)
}

const pane = z.object({ type: z.string(), title: z.string(), resourceUri: z.string() })
const ingress = z.object({
  name: z.string(),
  title: z.string().optional(),
  route: z.string().optional()
})
const panesSetting = z.object({ panes: z.array(pane) })
const ingressSetting = z.object({ ingress: z.array(ingress) })
const servedApp = z.object({ ui: z.object({ resourceUri: z.string() }) })
const eventList = z.object({ events: z.array(z.object({ name: z.string() })) })
const skillList = z.object({
  skills: z.array(
    z.object({ frontmatter: z.object({ name: z.string(), description: z.string() }) })
  )
})

const advertisedServer = z.object({
  _meta: z.object({
    "dev.codevisor/plugin": z.object({
      capabilities: z.object({
        tools: z.array(z.object({ name: z.string(), app: z.boolean().optional() })),
        events: z.array(z.object({ name: z.string() })),
        skills: z.array(z.object({ name: z.string(), description: z.string() })),
        panes: z.array(pane),
        ingress: z.array(ingress)
      })
    })
  })
})
