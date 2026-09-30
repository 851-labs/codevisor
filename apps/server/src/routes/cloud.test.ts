import { describe, expect, it } from "vitest"

import { defaultServerConfig, startCodevisorServer } from "../server.js"
import { jsonRequest, makeServices, run, runningServers } from "../test-support.js"

describe("cloud routes", () => {
  it("advertises the cloud device id when the machine is cloud-connected", async () => {
    const { services } = await makeServices("server-cloud")
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({
          bootId: "test-boot",
          id: "server-cloud",
          port: 0,
          cloudDeviceId: "device-123"
        })
      )
    )
    runningServers.push(server)
    expect((await jsonRequest(server, "/v1/info")).body).toMatchObject({
      cloudDeviceId: "device-123"
    })
    expect((await jsonRequest(server, "/v1/discovery")).body).toMatchObject({ cloudLinked: true })
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
    expect((await jsonRequest(server, "/v1/unknown", { method: "GET" })).status).toBe(404)
  })

  it("joins an account with a machine invite instead of a session", async () => {
    const { services } = await makeServices("server-cloud-invite")
    const joins: { inviteCode: string; options?: unknown }[] = []
    const cloud = {
      deviceId: () => undefined,
      state: () => undefined,
      managedBy: () => undefined,
      connect: () => Promise.reject(new Error("the session path must not run")),
      connectWithInvite: (inviteCode: string, options?: unknown) => {
        joins.push({ inviteCode, options })
        return Promise.resolve("device-invited")
      },
      disconnect: () => Promise.resolve({ removedFromAccount: true })
    }
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ bootId: "test-boot", id: "server-cloud-invite", port: 0, cloud })
      )
    )
    runningServers.push(server)
    const joined = await jsonRequest(server, "/v1/cloud/connect", {
      method: "POST",
      body: JSON.stringify({
        inviteCode: "cvi1.x.y",
        machineName: " hetzner-1 ",
        managedBy: "external"
      })
    })
    expect(joined).toEqual({ status: 200, body: { deviceId: "device-invited" } })
    expect(joins).toEqual([
      { inviteCode: "cvi1.x.y", options: { managedBy: "external", machineName: "hetzner-1" } }
    ])
  })

  it("drives the machine's cloud registration through live cloud control", async () => {
    const { services } = await makeServices("server-cloud-live")
    let bridgeDeviceId: string | undefined
    let lastConnect: { serverUrl: string; sessionToken: string; options?: unknown } | undefined
    let failWith: unknown
    let removedFromAccount = true
    const cloud = {
      deviceId: () => bridgeDeviceId,
      state: () => (bridgeDeviceId === undefined ? undefined : "connected"),
      serverUrl: () => (bridgeDeviceId === undefined ? undefined : "https://cloud.example"),
      managedBy: () => (bridgeDeviceId === undefined ? undefined : ("app" as const)),
      connect: (serverUrl: string, sessionToken: string, options?: unknown) => {
        if (failWith !== undefined) return Promise.reject(failWith)
        lastConnect = { serverUrl, sessionToken, options }
        bridgeDeviceId = "device-live"
        return Promise.resolve(bridgeDeviceId)
      },
      disconnect: () => {
        bridgeDeviceId = undefined
        return Promise.resolve({ removedFromAccount })
      }
    }
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ bootId: "test-boot", id: "server-cloud-live", port: 0, cloud })
      )
    )
    runningServers.push(server)

    // Disconnected: no device id anywhere, /v1/cloud says so.
    expect((await jsonRequest(server, "/v1/info")).body).not.toHaveProperty("cloudDeviceId")
    expect((await jsonRequest(server, "/v1/cloud")).body).toEqual({ connected: false })
    expect((await jsonRequest(server, "/v1/discovery")).body).toMatchObject({ cloudLinked: false })

    // A control that can't redeem invites says so rather than trying.
    const noInvites = await jsonRequest(server, "/v1/cloud/connect", {
      method: "POST",
      body: JSON.stringify({ inviteCode: "cvi1.x.y" })
    })
    expect(noInvites.status).toBe(501)

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
    expect(lastConnect).toEqual({
      serverUrl: "https://cloud.example",
      sessionToken: "session-1",
      options: {}
    })
    expect((await jsonRequest(server, "/v1/cloud")).body).toEqual({
      connected: true,
      deviceId: "device-live",
      state: "connected",
      serverUrl: "https://cloud.example",
      managedBy: "app"
    })
    expect((await jsonRequest(server, "/v1/info")).body).toMatchObject({
      cloudDeviceId: "device-live"
    })
    // Discovery follows the live registration, not the boot snapshot.
    expect((await jsonRequest(server, "/v1/discovery")).body).toMatchObject({ cloudLinked: true })

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

    for (const extra of [
      { managedBy: "invalid" },
      { machineName: 7 },
      { machineName: " " },
      { machineName: "x".repeat(121) }
    ]) {
      expect(
        (
          await jsonRequest(server, "/v1/cloud/connect", {
            method: "POST",
            body: JSON.stringify({
              serverUrl: "https://cloud.example",
              sessionToken: "session",
              ...extra
            })
          })
        ).status
      ).toBe(400)
    }
    expect(
      (
        await jsonRequest(server, "/v1/cloud/connect", {
          method: "POST",
          body: JSON.stringify({
            serverUrl: "https://cloud.example",
            sessionToken: "session-cli",
            managedBy: "external",
            machineName: " CLI machine "
          })
        })
      ).status
    ).toBe(200)
    expect(lastConnect).toEqual({
      serverUrl: "https://cloud.example",
      sessionToken: "session-cli",
      options: { managedBy: "external", machineName: "CLI machine" }
    })

    // Disconnect forgets the registration everywhere.
    const disconnected = await jsonRequest(server, "/v1/cloud/disconnect", { method: "POST" })
    expect(disconnected.status).toBe(200)
    expect(disconnected.body).toEqual({ ok: true, removedFromAccount: true })
    expect((await jsonRequest(server, "/v1/cloud")).body).toEqual({ connected: false })
    expect((await jsonRequest(server, "/v1/info")).body).not.toHaveProperty("cloudDeviceId")

    // An unreachable cloud still disconnects locally, with a warning that
    // the machine stays on the account until removed from an app.
    removedFromAccount = false
    const stranded = await jsonRequest(server, "/v1/cloud/disconnect", { method: "POST" })
    expect(stranded.status).toBe(200)
    expect(stranded.body).toMatchObject({ ok: true, removedFromAccount: false })
    expect((stranded.body as { warning?: string }).warning).toContain("machine list")
  })
})
