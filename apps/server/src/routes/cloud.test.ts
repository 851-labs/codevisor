import { describe, expect, it } from "vitest"
import { defaultServerConfig, startCodevisorServer } from "../server.js"
import { jsonRequest, makeServices, run, runningServers } from "../test-support.js"

describe("cloud routes", () => {
  it("advertises the cloud device id when the machine is cloud-connected", async () => {
    const { services } = await makeServices("server-cloud")
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ id: "server-cloud", port: 0, cloudDeviceId: "device-123" })
      )
    )
    runningServers.push(server)
    expect((await jsonRequest(server, "/v1/info")).body).toMatchObject({
      cloudDeviceId: "device-123"
    })
    // Without live control, /v1/cloud reflects the boot-time snapshot and
    // connect/disconnect are unavailable.
    expect((await jsonRequest(server, "/v1/cloud")).body).toEqual({
      connected: true,
      deviceId: "device-123"
    })
    expect(
      (
        await jsonRequest(server, "/v1/cloud/connect", {
          method: "POST",
          body: JSON.stringify({ serverUrl: "https://cloud.example", sessionToken: "token" })
        })
      ).status
    ).toBe(501)
    expect((await jsonRequest(server, "/v1/cloud/disconnect", { method: "POST" })).status).toBe(501)
    expect((await jsonRequest(server, "/v1/cloud/unknown", { method: "GET" })).status).toBe(404)
  })

  it("drives the machine's cloud registration through live cloud control", async () => {
    const { services } = await makeServices("server-cloud-live")
    let bridgeDeviceId: string | undefined
    let lastConnect: { serverUrl: string; sessionToken: string } | undefined
    let failWith: unknown
    const cloud = {
      deviceId: () => bridgeDeviceId,
      state: () => (bridgeDeviceId === undefined ? undefined : "connected"),
      managedBy: () => (bridgeDeviceId === undefined ? undefined : ("app" as const)),
      connect: (serverUrl: string, sessionToken: string) => {
        if (failWith !== undefined) return Promise.reject(failWith)
        lastConnect = { serverUrl, sessionToken }
        bridgeDeviceId = "device-live"
        return Promise.resolve(bridgeDeviceId)
      },
      disconnect: () => {
        bridgeDeviceId = undefined
        return Promise.resolve()
      }
    }
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ id: "server-cloud-live", port: 0, cloud })
      )
    )
    runningServers.push(server)

    // Disconnected: no device id anywhere, /v1/cloud says so.
    expect((await jsonRequest(server, "/v1/info")).body).not.toHaveProperty("cloudDeviceId")
    expect((await jsonRequest(server, "/v1/cloud")).body).toEqual({ connected: false })

    // Bad payloads are rejected before touching the control.
    expect(
      (
        await jsonRequest(server, "/v1/cloud/connect", {
          method: "POST",
          body: JSON.stringify({ serverUrl: 7 })
        })
      ).status
    ).toBe(400)

    // Connect registers the machine and the live device id shows up in info.
    const connected = await jsonRequest(server, "/v1/cloud/connect", {
      method: "POST",
      body: JSON.stringify({ serverUrl: "https://cloud.example", sessionToken: "session-1" })
    })
    expect(connected).toEqual({ status: 200, body: { deviceId: "device-live" } })
    expect(lastConnect).toEqual({ serverUrl: "https://cloud.example", sessionToken: "session-1" })
    expect((await jsonRequest(server, "/v1/cloud")).body).toEqual({
      connected: true,
      deviceId: "device-live",
      state: "connected",
      managedBy: "app"
    })
    expect((await jsonRequest(server, "/v1/info")).body).toMatchObject({
      cloudDeviceId: "device-live"
    })

    // Provisioning failures surface as a gateway error with the cause —
    // Error instances and bare thrown values alike.
    failWith = new Error("provisioning failed")
    const failed = await jsonRequest(server, "/v1/cloud/connect", {
      method: "POST",
      body: JSON.stringify({ serverUrl: "https://cloud.example", sessionToken: "session-2" })
    })
    expect(failed.status).toBe(502)
    expect(failed.body).toMatchObject({ error: expect.stringContaining("provisioning failed") })
    failWith = "socket hangup"
    const failedBare = await jsonRequest(server, "/v1/cloud/connect", {
      method: "POST",
      body: JSON.stringify({ serverUrl: "https://cloud.example", sessionToken: "session-3" })
    })
    expect(failedBare.status).toBe(502)
    expect(failedBare.body).toMatchObject({ error: expect.stringContaining("socket hangup") })
    failWith = undefined

    // Disconnect forgets the registration everywhere.
    expect((await jsonRequest(server, "/v1/cloud/disconnect", { method: "POST" })).status).toBe(200)
    expect((await jsonRequest(server, "/v1/cloud")).body).toEqual({ connected: false })
    expect((await jsonRequest(server, "/v1/info")).body).not.toHaveProperty("cloudDeviceId")
  })
})
