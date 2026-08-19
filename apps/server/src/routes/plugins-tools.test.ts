import { describe, expect, it } from "vitest"
import {
  jsonRequest,
  makeServices,
  pluginsStub,
  runningServers,
  startWithApp
} from "../test-support.js"

/// POST /v1/plugins/:pluginId/tools/:toolName — the authorized invocation
/// route behind agents' `plugin.<pluginId>.<toolName>` gateway tools.

describe("plugin tool routes", () => {
  it("invokes plugin tools, forwarding args and caller context verbatim", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<Array<unknown>> = []
    const server = await startWithApp({ ...services, plugins: pluginsStub(calls) })
    runningServers.push(server)

    const invoked = await jsonRequest(server, "/v1/plugins/owner.example/tools/notes_add", {
      body: JSON.stringify({ args: { text: "hi" }, cwd: "/tmp/project", workspaceId: "w1" }),
      method: "POST"
    })
    expect(invoked.status).toBe(200)
    expect(invoked.body).toEqual({ added: true, received: { text: "hi" } })
    expect(calls).toContainEqual([
      "invokeTool",
      "owner.example",
      "notes_add",
      { text: "hi" },
      { cwd: "/tmp/project", workspaceId: "w1" }
    ])

    // args and context are all optional: an empty body invokes with defaults.
    const bare = await jsonRequest(server, "/v1/plugins/owner.example/tools/notes_add", {
      body: JSON.stringify({}),
      method: "POST"
    })
    expect(bare.status).toBe(200)
    expect(calls).toContainEqual(["invokeTool", "owner.example", "notes_add", {}, {}])
  })

  it("maps unknown tools, unknown plugins, and invalid bodies onto statuses", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<Array<unknown>> = []
    const server = await startWithApp({ ...services, plugins: pluginsStub(calls) })
    runningServers.push(server)

    expect(
      (
        await jsonRequest(server, "/v1/plugins/owner.example/tools/ghost_tool", {
          body: JSON.stringify({}),
          method: "POST"
        })
      ).status
    ).toBe(404)
    expect(
      (
        await jsonRequest(server, "/v1/plugins/owner.ghost/tools/notes_add", {
          body: JSON.stringify({}),
          method: "POST"
        })
      ).status
    ).toBe(404)
    expect(
      (
        await jsonRequest(server, "/v1/plugins/owner.example/tools/notes_add", {
          body: JSON.stringify({ args: "not-an-object" }),
          method: "POST"
        })
      ).status
    ).toBe(400)
    // Only POST invokes; other methods fall through to 404.
    expect((await jsonRequest(server, "/v1/plugins/owner.example/tools/notes_add")).status).toBe(
      404
    )
  })
})
