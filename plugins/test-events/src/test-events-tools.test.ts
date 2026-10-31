import { heartbeatIntervalMs } from "@codevisor/plugin-kit"
import {
  type ConnectedClient,
  connectClient,
  manualClock,
  openStream,
  toolText
} from "@codevisor/plugin-kit/test-support"
import type { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { afterEach, describe, expect, it } from "vitest"
import { z } from "zod"

import { eventsPageScript } from "./events-page.js"
import { createTestEventsServer, testEventsOptionsFromEnv } from "./test-events-server.js"

const connections: Array<ConnectedClient> = []

const connect = async (options: Parameters<typeof createTestEventsServer>[0] = {}) => {
  const clock = manualClock()
  const connected = await connectClient(createTestEventsServer({ clock, ...options }))
  connections.push(connected)
  return { ...connected, clock }
}

const skillListing = z
  .object({
    skills: z.array(
      z.object({
        uri: z.string(),
        frontmatter: z.record(z.string(), z.string()),
        resources: z.array(z.object({ uri: z.string(), digest: z.string(), size: z.number() }))
      })
    )
  })
  .loose()

const readText = async (client: Client, uri: string): Promise<string> =>
  toolText({ content: (await client.readResource({ uri })).contents })

describe("test-events tools", () => {
  afterEach(async () => {
    await Promise.all(connections.splice(0).map((connected) => connected.client.close()))
  })

  it("links show_events to its MCP App resource", async () => {
    const { client } = await connect()

    const { tools } = await client.listTools()

    expect(tools.map((tool) => tool.name)).toEqual(["emit", "list_recent", "show_events"])
    expect(tools[2]?._meta).toEqual({ ui: { resourceUri: "ui://test-events/events.html" } })
  })

  it("lists recent events through list_recent and show_events", async () => {
    const { client } = await connect()
    await client.callTool({ name: "emit", arguments: { name: "test.ping", eventId: "a" } })
    await client.callTool({ name: "emit", arguments: { name: "test.counter", eventId: "b" } })

    const recent = await client.callTool({ name: "list_recent", arguments: { limit: 1 } })
    const shown = await client.callTool({ name: "show_events" })

    expect(recent.structuredContent).toMatchObject({
      events: [{ eventId: "b", data: { value: 2 } }]
    })
    expect(JSON.parse(toolText(recent))).toEqual(recent.structuredContent)
    expect(shown.structuredContent).toMatchObject({ events: [{ eventId: "a" }, { eventId: "b" }] })
  })

  it("reports invalid tool calls as tool errors", async () => {
    const { client } = await connect()

    const badEmit = await client.callTool({ name: "emit", arguments: { name: "test.unknown" } })
    const badLimit = await client.callTool({ name: "list_recent", arguments: { limit: 0 } })
    const unknown = await client.callTool({ name: "explode", arguments: {} })

    expect(badEmit.isError).toBe(true)
    expect(toolText(badEmit)).toContain("name")
    expect(badLimit.isError).toBe(true)
    expect(unknown).toEqual({
      content: [{ type: "text", text: "Unknown tool: explode" }],
      isError: true
    })
  })

  it("emits counter ticks on the configured interval to open streams", async () => {
    const connected = await connect({ intervalMs: 5_000 })
    const stream = await openStream(connected, { name: "test.counter", cursor: null })

    connected.clock.advance(heartbeatIntervalMs)
    const heartbeat = await connected.inbox.next(
      "notifications/events/heartbeat",
      stream.subscriptionId
    )
    const ticks = connected.inbox
      .forSubscription(stream.subscriptionId)
      .filter((message) => message.method === "notifications/events/event")

    expect(ticks.map((tick) => [tick.params?.["timestamp"], tick.params?.["data"]])).toEqual([
      ["2026-10-27T12:00:05.000Z", { value: 1 }],
      ["2026-10-27T12:00:10.000Z", { value: 2 }],
      ["2026-10-27T12:00:15.000Z", { value: 3 }]
    ])
    expect(heartbeat.params?.["cursor"]).toBe(ticks[2]?.params?.["cursor"])
  })

  it("reads the timer interval from the environment", () => {
    expect(testEventsOptionsFromEnv({ CODEVISOR_TEST_EVENTS_INTERVAL_MS: "5000" })).toEqual({
      intervalMs: 5_000
    })
    expect(testEventsOptionsFromEnv({ CODEVISOR_TEST_EVENTS_INTERVAL_MS: "soon" })).toEqual({})
    expect(testEventsOptionsFromEnv({ CODEVISOR_TEST_EVENTS_INTERVAL_MS: "-1" })).toEqual({})
    expect(testEventsOptionsFromEnv({})).toEqual({})
  })
})

describe("test-events skills and resources", () => {
  afterEach(async () => {
    await Promise.all(connections.splice(0).map((connected) => connected.client.close()))
  })

  it("serves its skill and reference file at the uris the listing names", async () => {
    const { client } = await connect()

    const listed = await client.request({ method: "skills/list", params: {} }, skillListing)
    const uris = listed.skills.flatMap((skill) => skill.resources.map((entry) => entry.uri))
    const texts = await Promise.all(uris.map((uri) => readText(client, uri)))

    expect(uris).toEqual([
      "skill://test-events/SKILL.md",
      "skill://test-events/references/payloads.md"
    ])
    expect(texts.map((text) => text.split("\n").find((line) => line.startsWith("# ")))).toEqual([
      "# Test events",
      "# Payloads"
    ])
  })

  it("lists and serves the MCP App page with the app mime type", async () => {
    const { client } = await connect()

    const { resources } = await client.listResources()
    const page = await client.readResource({ uri: "ui://test-events/events.html" })

    expect(resources[0]).toEqual({
      uri: "ui://test-events/events.html",
      name: "Test events",
      mimeType: "text/html;profile=mcp-app"
    })
    expect(page.contents[0]).toMatchObject({
      uri: "ui://test-events/events.html",
      mimeType: "text/html;profile=mcp-app",
      text: expect.stringContaining(`<script>${eventsPageScript}</script>`)
    })
    await expect(
      client.readResource({ uri: "ui://test-events/missing.html" })
    ).rejects.toMatchObject({ code: -32002 })
  })
})
