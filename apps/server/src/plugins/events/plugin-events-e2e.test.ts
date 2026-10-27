import { decode, PluginEventSubscription } from "@codevisor/api"
import { expect, it } from "vitest"

import { run, waitFor } from "../../test-support.js"
import { stringField } from "../../unknown-values.js"
import {
  createChat,
  installTestEvents,
  pluginEventPrompts,
  post,
  startPluginServer,
  type PluginServer
} from "../plugin-test-support.js"
import { sourceKeyOf } from "./plugin-event-source-key.js"

const emit = async (running: PluginServer, serverId: string, data: Record<string, unknown>) => {
  const connection = await running.mcp.pluginConnection(serverId)
  await connection.request("tools/call", { name: "emit", arguments: { name: "test.ping", data } })
}

it("wakes an idle chat exactly once when the test-events plugin emits a matching ping", async () => {
  const running = await startPluginServer()
  const plugin = await installTestEvents(running)
  const watcher = await createChat(running, "Watcher")

  const subscribed = await post(running, "/v1/plugins/events/subscriptions", {
    sessionId: watcher,
    plugin: "Test Events",
    event: "test.ping",
    filter: 'level == "error"',
    note: "Plugin errors"
  })
  const subscription = decode(PluginEventSubscription)(subscribed.body)
  const sourceKey = sourceKeyOf({ serverId: plugin.id, eventName: "test.ping", arguments: {} })
  await waitFor(
    async () => (await run(running.services.db.pluginEventCursor(sourceKey))) !== undefined
  )
  await emit(running, plugin.id, { level: "info", message: "all good" })
  await emit(running, plugin.id, { level: "error", message: "disk full" })
  await waitFor(() => pluginEventPrompts(running).length === 1)

  const stored = await run(running.services.db.recentPluginEvents(plugin.id, "test.ping", 10))
  expect(subscription.explained).toBe('level is "error"')
  expect(stored.map((event) => stringField(event.data, "level"))).toEqual(["error", "info"])
  expect(pluginEventPrompts(running)).toEqual([
    expect.stringContaining(
      `<codevisor-event type="plugin.event" plugin="Test Events" event="test.ping" subscriptionId="${subscription.id}" note="Plugin errors" eventId="${stored[0]!.id}"`
    )
  ])
  expect(pluginEventPrompts(running)[0]).toContain('"message":"disk full"')
})
