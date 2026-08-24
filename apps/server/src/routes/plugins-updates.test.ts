import { describe, expect, it } from "vitest"
import {
  jsonRequest,
  makeServices,
  pluginsStub,
  readSseEvents,
  runningServers,
  startWithApp
} from "../test-support.js"

describe("plugin update routes", () => {
  it("lists, prepares, and applies plugin updates", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<Array<unknown>> = []
    const server = await startWithApp({ ...services, plugins: pluginsStub(calls) })
    runningServers.push(server)

    const updates = await jsonRequest(server, "/v1/plugins/updates")
    expect(updates.status).toBe(200)
    expect(updates.body).toMatchObject({
      updates: [{ pluginId: "owner.example", state: "available" }]
    })
    const prepared = await jsonRequest(server, "/v1/plugins/owner.example/update/prepare", {
      method: "POST"
    })
    expect(prepared.status).toBe(201)
    expect(prepared.body).toMatchObject({ planId: "plan-1", pluginId: "owner.example" })

    const live = readSseEvents(server, 1)
    const applied = await jsonRequest(server, "/v1/plugins/owner.example/update/apply", {
      body: JSON.stringify({ planId: "plan-1" }),
      method: "POST"
    })
    expect(applied).toMatchObject({ status: 200, body: { version: "0.2.0" } })
    expect(calls).toContainEqual(["listUpdates"])
    expect(calls).toContainEqual(["prepareUpdate", "owner.example"])
    expect(calls).toContainEqual(["applyUpdate", "owner.example", "plan-1"])
    expect(await live).toContainEqual(
      expect.objectContaining({ kind: "plugin.updated", subjectId: "owner.example" })
    )
  })
})
