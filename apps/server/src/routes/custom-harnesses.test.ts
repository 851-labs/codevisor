import { describe, expect, it } from "vitest"
import { jsonRequest, makeServices, runningServers, startWithApp } from "../test-support.js"

describe("custom harness routes", () => {
  const makeStore = () => {
    const replaced: Array<ReadonlyArray<unknown>> = []
    const tested: Array<unknown> = []
    return {
      replaced,
      tested,
      store: {
        list: async () => [{ command: "my-agent", id: "mine", name: "Mine" }],
        replace: async (specs: ReadonlyArray<unknown>) => {
          replaced.push(specs)
        },
        test: async (spec: unknown) => {
          tested.push(spec)
          return { agentName: "Mine", ok: true, protocolVersion: 1 }
        }
      }
    }
  }

  it("lists custom harnesses", async () => {
    const { services } = await makeServices("server-a")
    const { store } = makeStore()
    const server = await startWithApp({ ...services, customHarnesses: store })
    runningServers.push(server)

    const response = await jsonRequest(server, "/v1/harnesses/custom")
    expect(response.status).toBe(200)
    expect(response.body).toEqual({
      harnesses: [{ command: "my-agent", id: "mine", name: "Mine" }]
    })
  })

  it("replaces the list and returns the refreshed harness catalog", async () => {
    const { services } = await makeServices("server-a")
    const { replaced, store } = makeStore()
    const server = await startWithApp({ ...services, customHarnesses: store })
    runningServers.push(server)

    const response = await jsonRequest(server, "/v1/harnesses/custom", {
      body: JSON.stringify({
        harnesses: [{ args: ["acp"], command: "my-agent", id: "mine", name: "Mine" }]
      }),
      method: "PUT"
    })
    expect(response.status).toBe(200)
    // Blocking rescan semantics: the fresh discovery list comes back.
    expect(response.body).toMatchObject([{ id: "codex" }])
    expect(replaced).toEqual([[{ args: ["acp"], command: "my-agent", id: "mine", name: "Mine" }]])
  })

  it("rejects invalid replacement lists without persisting", async () => {
    const { services } = await makeServices("server-a")
    const { replaced, store } = makeStore()
    const server = await startWithApp({ ...services, customHarnesses: store })
    runningServers.push(server)

    const response = await jsonRequest(server, "/v1/harnesses/custom", {
      body: JSON.stringify({
        harnesses: [{ command: "fake-codex", id: "codex", name: "Fake Codex" }]
      }),
      method: "PUT"
    })
    expect(response.status).toBe(400)
    expect(replaced).toEqual([])
  })

  it("runs the ACP handshake test for a spec", async () => {
    const { services } = await makeServices("server-a")
    const { store, tested } = makeStore()
    const server = await startWithApp({ ...services, customHarnesses: store })
    runningServers.push(server)

    const response = await jsonRequest(server, "/v1/harnesses/custom/test", {
      body: JSON.stringify({ command: "my-agent", id: "mine", name: "Mine" }),
      method: "POST"
    })
    expect(response.status).toBe(200)
    expect(response.body).toEqual({ agentName: "Mine", ok: true, protocolVersion: 1 })
    expect(tested).toHaveLength(1)
  })

  it("rejects an invalid test spec", async () => {
    const { services } = await makeServices("server-a")
    const { store, tested } = makeStore()
    const server = await startWithApp({ ...services, customHarnesses: store })
    runningServers.push(server)

    const response = await jsonRequest(server, "/v1/harnesses/custom/test", {
      body: JSON.stringify({ command: "", id: "bad", name: "Bad" }),
      method: "POST"
    })
    expect(response.status).toBe(400)
    expect(tested).toEqual([])
  })

  it("returns 501 when the host has no custom-harness store", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp(services)
    runningServers.push(server)

    const response = await jsonRequest(server, "/v1/harnesses/custom")
    expect(response.status).toBe(501)
  })
})
