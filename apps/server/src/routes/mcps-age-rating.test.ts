import { decode, McpServer } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import {
  installTestEvents,
  startPluginServer,
  testEventsId
} from "../plugins/plugin-test-support.js"
import { jsonRequest } from "../test-support.js"

describe("plugin age ratings on the plugin list", () => {
  it("adds the catalog rating to installed catalog plugins only", async () => {
    const running = await startPluginServer()
    await installTestEvents(running)
    await running.mcp.create({
      name: "Mine",
      transport: "stdio",
      command: "my-mcp",
      enabled: false
    })

    const listed = decode(Schema.Array(McpServer))(
      (await jsonRequest(running.server, "/v1/mcps")).body
    )

    expect(listed.find((server) => server.catalogId === testEventsId)?.ageRating).toBe(4)
    expect(listed.find((server) => server.name === "Mine")).not.toHaveProperty("ageRating")
  })
})
