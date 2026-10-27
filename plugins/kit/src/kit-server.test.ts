import { createHash } from "node:crypto"

import { Server } from "@modelcontextprotocol/sdk/server/index.js"
import { CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js"
import { afterEach, describe, expect, it } from "vitest"
import { z } from "zod"

import {
  accountFromMeta,
  createEventStreams,
  emptyArguments,
  errorResult,
  eventsExtension,
  eventsPollRequest,
  eventsStreamRequest,
  type EventStreams,
  eventTypeNamed,
  forbiddenError,
  heartbeatIntervalMs,
  invalidParamsError,
  jsonResult,
  registerEventTypes,
  registerResources,
  registerSkills,
  skillCatalog,
  skillsExtension,
  structuredResult,
  unsupportedDeliveryError
} from "./index.js"
import {
  anyResult,
  type ConnectedClient,
  connectClient,
  type ManualClock,
  manualClock,
  openStream,
  toolText,
  withAccount
} from "./plugin-server-test-support.js"

const eventTypes = [
  {
    name: "demo.happened",
    description: "Something happened",
    delivery: ["push" as const],
    inputSchema: emptyArguments,
    payloadSchema: { type: "object", properties: { value: { type: "integer" } } }
  }
]

const skills = skillCatalog([
  {
    name: "demo",
    description: "Demo: a skill with a reference file",
    instructions: "# Demo\n\nRead `references/notes.md`.\n",
    files: [{ path: "references/notes.md", mimeType: "text/markdown", text: "# Notes\n" }]
  }
])

interface DemoServer {
  server: Server
  streams: EventStreams
  clock: ManualClock
}

const demoServer = (): DemoServer => {
  const clock = manualClock()
  const streams = createEventStreams({ clock, heartbeatCursor: () => `at-${clock.now()}` })
  const server = new Server(
    { name: "demo", version: "1.0.0" },
    {
      capabilities: {
        tools: {},
        resources: {},
        extensions: { [eventsExtension]: {}, [skillsExtension]: {} }
      }
    }
  )
  registerEventTypes(server, eventTypes)
  registerSkills(server, skills)
  registerResources(server, skills.resources)
  server.setRequestHandler(eventsPollRequest, (request) => {
    eventTypeNamed(eventTypes, request.params.name)
    throw unsupportedDeliveryError("poll")
  })
  server.setRequestHandler(eventsStreamRequest, (request, extra) => {
    eventTypeNamed(eventTypes, request.params.name)
    const account = accountFromMeta(extra._meta)
    if (account === undefined) throw forbiddenError("account required")

    const backlog = [
      {
        eventId: "e0",
        name: request.params.name,
        timestamp: "t0",
        data: { value: 0 },
        cursor: "c0"
      }
    ]
    return streams.open(
      {
        name: request.params.name,
        accountId: account.id,
        position: { cursor: "c0", truncated: false },
        backlog
      },
      extra
    )
  })
  server.setRequestHandler(CallToolRequestSchema, (request) => {
    if (request.params.name === "json") return jsonResult([1, 2])
    if (request.params.name === "structured") return structuredResult({ ok: true })
    if (request.params.name === "invalid") throw invalidParamsError("bad input")
    return errorResult("nope")
  })
  return { server, streams, clock }
}

const connections: Array<ConnectedClient> = []

const connect = async () => {
  const demo = demoServer()
  const connected = await connectClient(demo.server)
  connections.push(connected)
  return { ...demo, ...connected }
}

const occurrence = (eventId: string) => ({
  eventId,
  name: "demo.happened",
  timestamp: "t1",
  data: { value: 1 },
  cursor: "c1"
})

describe("plugin kit", () => {
  afterEach(async () => {
    await Promise.all(connections.splice(0).map((connected) => connected.client.close()))
  })

  it("lists event types and rejects unknown ones with NotFound", async () => {
    const { client } = await connect()

    const listed = await client.request({ method: "events/list" }, anyResult)

    expect(listed).toEqual({ resultType: "complete", events: eventTypes })
    await expect(
      client.request({ method: "events/poll", params: { name: "demo.other" } }, anyResult)
    ).rejects.toMatchObject({ code: -32023, data: { kind: "event" } })
    await expect(
      client.request({ method: "events/poll", params: { name: "demo.happened" } }, anyResult)
    ).rejects.toMatchObject({ code: -32026, data: { feature: "deliveryMode", value: "poll" } })
  })

  it("streams the backlog, then events for the stream's account, with heartbeats", async () => {
    const connected = await connect()
    const mine = await openStream(connected, {
      name: "demo.happened",
      _meta: withAccount("a1", {})
    })
    const backlog = await connected.inbox.next("notifications/events/event", mine.subscriptionId)
    const theirs = await openStream(connected, {
      name: "demo.happened",
      _meta: withAccount("a2", {})
    })

    const delivered = connected.streams.publish(
      occurrence("e1"),
      (stream) => stream.accountId === "a1"
    )
    const live = await connected.inbox.next("notifications/events/event", mine.subscriptionId)
    connected.clock.advance(heartbeatIntervalMs)
    const heartbeat = await connected.inbox.next(
      "notifications/events/heartbeat",
      mine.subscriptionId
    )

    expect(mine.active.params).toEqual({
      cursor: "c0",
      truncated: false,
      _meta: { "io.modelcontextprotocol/subscriptionId": mine.subscriptionId }
    })
    expect([backlog.params?.["eventId"], live.params?.["eventId"], delivered]).toEqual([
      "e0",
      "e1",
      1
    ])
    expect(heartbeat.params?.["cursor"]).toBe(`at-${connected.clock.now()}`)
    expect(
      connected.inbox
        .forSubscription(theirs.subscriptionId)
        .filter((message) => message.method === "notifications/events/event")
        .map((message) => message.params?.["eventId"])
    ).toEqual(["e0"])
  })

  it("stops a stream on cancellation and frees its heartbeat", async () => {
    const connected = await connect()
    const cancel = new AbortController()
    const stream = await openStream(
      connected,
      { name: "demo.happened", _meta: withAccount("a1", {}) },
      cancel.signal
    )

    cancel.abort()
    await expect(stream.closed).rejects.toThrow()
    await connected.client.request({ method: "events/list" }, anyResult)

    expect(connected.streams.count()).toBe(0)
    expect(connected.clock.timers()).toBe(0)
    expect(connected.streams.publish(occurrence("e2"), () => true)).toBe(0)
  })

  it("refuses a stream without an account", async () => {
    const { client } = await connect()

    await expect(
      client.request({ method: "events/stream", params: { name: "demo.happened" } }, anyResult)
    ).rejects.toMatchObject({ code: -32024, data: { reason: "account required" } })
  })

  it("lists and gets skills whose manifest matches the served bytes", async () => {
    const { client } = await connect()

    const listed = await client.request({ method: "skills/list" }, anyResult)
    const got = await client.request(
      { method: "skills/get", params: { uri: "skill://demo/SKILL.md" } },
      anyResult
    )
    const markdown = await client.readResource({ uri: "skill://demo/SKILL.md" })
    const text = toolText({ content: markdown.contents })

    expect(listed).toMatchObject({ resultType: "complete", ttlMs: 300_000, cacheScope: "public" })
    expect(got["skill"]).toEqual(z.array(z.unknown()).parse(listed["skills"])[0])
    expect(text).toBe(
      '---\nname: "demo"\ndescription: "Demo: a skill with a reference file"\n---\n\n# Demo\n\nRead `references/notes.md`.\n'
    )
    expect(got["skill"]).toEqual({
      uri: "skill://demo/SKILL.md",
      frontmatter: { name: "demo", description: "Demo: a skill with a reference file" },
      resources: [
        { uri: "skill://demo/SKILL.md", digest: sha256(text), size: Buffer.byteLength(text) },
        { uri: "skill://demo/references/notes.md", digest: sha256("# Notes\n"), size: 8 }
      ]
    })
    await expect(
      client.request(
        { method: "skills/get", params: { uri: "skill://missing/SKILL.md" } },
        anyResult
      )
    ).rejects.toMatchObject({ code: -32602 })
  })

  it("lists resources without their bodies and rejects unknown uris", async () => {
    const { client } = await connect()

    const { resources } = await client.listResources()

    expect(resources).toEqual([
      { uri: "skill://demo/SKILL.md", name: "demo/SKILL.md", mimeType: "text/markdown" },
      {
        uri: "skill://demo/references/notes.md",
        name: "demo/references/notes.md",
        mimeType: "text/markdown"
      }
    ])
    await expect(client.readResource({ uri: "skill://demo/missing.md" })).rejects.toMatchObject({
      code: -32002,
      data: { uri: "skill://demo/missing.md" }
    })
  })

  it("builds text, structured and error tool results", async () => {
    const { client } = await connect()

    const json = await client.callTool({ name: "json", arguments: {} })
    const structured = await client.callTool({ name: "structured", arguments: {} })
    const failed = await client.callTool({ name: "other", arguments: {} })

    expect(json).toEqual({ content: [{ type: "text", text: "[\n  1,\n  2\n]" }] })
    expect(structured).toEqual({
      content: [{ type: "text", text: '{\n  "ok": true\n}' }],
      structuredContent: { ok: true }
    })
    expect(failed).toEqual({ content: [{ type: "text", text: "nope" }], isError: true })
    await expect(client.callTool({ name: "invalid", arguments: {} })).rejects.toMatchObject({
      code: -32602
    })
  })
})

describe("accountFromMeta", () => {
  it("reads the per-request account and ignores malformed ones", () => {
    const meta = {
      "dev.codevisor/account": { id: "a1", accessToken: "tok", identity: "me@example.com" }
    }

    expect(accountFromMeta(meta)).toEqual({
      id: "a1",
      accessToken: "tok",
      identity: "me@example.com",
      fields: {}
    })
    expect(accountFromMeta({ "dev.codevisor/account": { label: "no id" } })).toBeUndefined()
    expect(accountFromMeta(undefined)).toBeUndefined()
  })
})

const sha256 = (text: string): string =>
  `sha256:${createHash("sha256").update(text, "utf8").digest("hex")}`
