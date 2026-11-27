import { randomUUID } from "node:crypto"

import type { ScreenSharingRequest } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import type { CodevisorServerConfig } from "./server.js"
import { jsonRequest, makeServices, run, startWithApp } from "./test-support.js"

const capabilities = (): ScreenSharingRequest => ({
  version: 1,
  operation: "capabilities",
  workspaceId: randomUUID(),
  paneId: randomUUID(),
  viewerId: randomUUID()
})
const reply = { version: 1, status: "available", displays: [] }
const media = { endpointId: "a".repeat(64), directAddrs: ["192.168.1.2:4433"] }
const app = { key: media.endpointId, name: "Alexandru's MacBook Pro" }
const proof = { nonce: "c".repeat(64), signature: "d".repeat(128) }
const session = "e".repeat(64)
const machineName = "Studio Mac"
const updateReply = {
  version: 1,
  status: "unavailable",
  reason: "update-needed",
  message: `Update Codevisor on this device to view ${machineName}.`,
  displays: []
}
const appCapabilities = (): ScreenSharingRequest => ({ ...capabilities(), app })
const appStart = (): ScreenSharingRequest => ({
  ...capabilities(),
  operation: "start",
  displayId: randomUUID(),
  engine: "v2",
  media,
  app,
  intent: "open",
  proof
})
const grant = {
  endpointId: "b".repeat(64),
  directAddrs: ["192.168.1.3:4433"],
  token: "t".repeat(64)
}

const fixture = async (
  screenSharing: (request: ScreenSharingRequest) => Promise<unknown> = async () => reply,
  configOverrides: Partial<CodevisorServerConfig> = {}
) => {
  const { services } = await makeServices()
  const server = await startWithApp(services, undefined, {
    name: machineName,
    screenSharing,
    ...configOverrides
  })
  const request = appStart()
  const post = (body: unknown = request, headers: Record<string, string> = {}) =>
    jsonRequest(server, "/v1/screen-sharing", {
      method: "POST",
      body: JSON.stringify(body),
      headers
    })
  return { server, services, request, post }
}

describe("app-owned Screen Sharing sessions", () => {
  it("serves an app's desktop session without a workspace or pane, and a heartbeat or stop that carries its session token", async () => {
    const helper = vi.fn(async () => reply)
    const { post } = await fixture(helper)
    const start = appStart()
    const { displayId: _, ...anyDisplay } = start
    const { app: __, intent: ___, proof: ____, ...stable } = start
    const beat = { ...stable, operation: "heartbeat", session }
    for (const request of [
      start,
      anyDisplay,
      beat,
      { ...beat, displayId: undefined },
      { ...stable, operation: "stop", session }
    ])
      expect((await post(request)).status).toBe(200)
    expect(helper).toHaveBeenCalledTimes(5)
    expect(helper).toHaveBeenCalledWith(start)
    expect(helper).toHaveBeenCalledWith(beat)

    expect((await post({ ...start, operation: "restart" })).status).toBe(400)
    expect(helper).toHaveBeenCalledTimes(5)
  })

  it("serves an app's Computer Use and Simulator streams without a workspace or pane", async () => {
    const helper = vi.fn(async () => reply)
    const { post } = await fixture(helper)
    for (const displayId of [
      `computer-use:${randomUUID().toUpperCase()}`,
      `simulator:${randomUUID()}`
    ]) {
      const start = { ...appStart(), displayId }
      const { app: _, intent: __, proof: ___, ...stable } = start
      const beat = { ...stable, operation: "heartbeat", session }
      for (const request of [start, beat, { ...beat, operation: "stop" }])
        expect((await post(request)).status).toBe(200)
      expect(helper).toHaveBeenCalledWith(start)
      expect(helper).toHaveBeenCalledWith(beat)
    }
    expect(helper).toHaveBeenCalledTimes(6)
  })

  it("rejects a malformed app, a start under another key, and a start that doesn't say open or attach", async () => {
    const helper = vi.fn(async () => reply)
    const { post } = await fixture(helper)
    for (const change of [
      { app: { ...app, key: "not-hex" } },
      { app: { ...app, name: " \n\u0007 " } },
      { app: { ...app, key: "c".repeat(64) } },
      { intent: undefined },
      { intent: "steal" },
      { displayId: "invalid" },
      { displayId: "computer-use:" },
      { displayId: "computer-use:invalid" },
      { displayId: "window:1" },
      { proof: undefined },
      { proof: { ...proof, nonce: "short" } },
      { proof: { ...proof, signature: "d".repeat(127) } },
      { session: "not-a-token" }
    ])
      expect((await post({ ...appStart(), ...change })).status).toBe(400)
    expect(
      (await post({ ...appStart(), operation: "heartbeat", session: "not-a-token" })).status
    ).toBe(400)
    expect(
      (await post({ ...appStart(), operation: "heartbeat", app: { key: "x", name: "n" } })).status
    ).toBe(400)
    expect(helper).not.toHaveBeenCalled()
    expect(
      (await post({ ...appStart(), app: { ...app, key: app.key.toUpperCase() }, intent: "attach" }))
        .status
    ).toBe(200)
  })

  it("gives the host a one-line app name of at most 64 characters", async () => {
    const helper = vi.fn<(request: ScreenSharingRequest) => Promise<unknown>>(async () => reply)
    const { post } = await fixture(helper)
    for (const name of ["  Alexandru's\r\nMac\u0000Book\u2028 Pro\t ", "😀".repeat(70)])
      await post({ ...appStart(), app: { ...app, name } })
    expect(helper.mock.calls.map(([request]) => request.app?.name)).toEqual([
      "Alexandru'sMacBook Pro",
      "😀".repeat(64)
    ])
  })
  it("passes on why the host refused or ended, who holds the session, what it shares and what it can do", async () => {
    const display = { id: randomUUID(), name: "Built-in Display", width: 3024, height: 1964 }
    const refused = {
      ...reply,
      status: "busy",
      message: "This Mac is already sharing with another viewer.",
      reason: "in-use",
      holderName: "Alexandru's iPhone",
      abilities: ["app-sessions"],
      challenge: { hostKey: "b".repeat(64), nonce: "c".repeat(64) }
    }
    const viewing = {
      ...reply,
      status: "viewing",
      display,
      displays: [display],
      reason: "a-later-reason",
      session
    }
    const helper = vi.fn(async (): Promise<unknown> => ({ ...refused, laterField: true }))
    const { post } = await fixture(helper)
    expect((await post({ ...appStart(), intent: "attach" })).body).toEqual(refused)
    helper.mockResolvedValueOnce(viewing)
    expect((await post({ ...appStart(), operation: "heartbeat", session })).body).toEqual(viewing)
  })
})

describe("viewers without an app identity", () => {
  it("get the update reply naming this machine, for every operation and native target, without reaching the host", async () => {
    const helper = vi.fn(async () => reply)
    const { post } = await fixture(helper)
    const { app: _, intent: __, proof: ___, ...appless } = appStart()
    const targets = [
      randomUUID(),
      undefined,
      `simulator:${randomUUID()}`,
      `computer-use:${randomUUID()}`
    ]
    const operations = ["capabilities", "start", "restart", "heartbeat", "setScale"] as const
    for (const displayId of targets)
      for (const operation of operations) {
        const answered = await post({ ...appless, operation, displayId })
        expect(answered.status).toBe(200)
        expect(answered.body).toEqual(updateReply)
      }
    const { engine: ____, media: _____, ...bare } = appless
    expect((await post({ ...bare, operation: "start" })).body).toEqual(updateReply)
    expect(helper).not.toHaveBeenCalled()
  })

  it("still pass on a stop, which only ends things: a viewer cancels a pending start with neither app nor session", async () => {
    const helper = vi.fn(async () => ({ ...reply, status: "stopped" }))
    const { post } = await fixture(helper)
    const { app: _, intent: __, proof: ___, ...appless } = appStart()
    const stop = { ...appless, operation: "stop" }
    expect((await post(stop)).body).toEqual({ ...reply, status: "stopped" })
    expect(helper).toHaveBeenCalledWith(stop)
  })

  it("leave a VNC machine's requests to its desktop, as before", async () => {
    const native = vi.fn(async () => reply)
    const respond = vi.fn(async () => ({ ...reply, provider: "vnc" }))
    const config = { socket: "/run/user/1000/codevisor-desktop.sock", name: "Desktop" }
    const { post } = await fixture(native, {
      desktops: { current: () => ({ displays: [config], respond }) }
    })
    const answered = await post(capabilities())
    expect(answered.status).toBe(200)
    expect(answered.body).toEqual({ ...reply, provider: "vnc" })
    expect(respond).toHaveBeenCalledOnce()
    expect(native).not.toHaveBeenCalled()
  })
})

describe("native Screen Sharing signaling", () => {
  it("requires machine authentication and rejects browser-originated requests", async () => {
    const helper = vi.fn(async () => reply)
    const { services } = await makeServices()
    const token = await run(services.db.issuePairingToken)
    const server = await startWithApp(services, undefined, {
      screenSharing: helper,
      auth: { allowLocalhostWithoutAuth: false, requireBearerToken: true }
    })
    const request = { method: "POST", body: JSON.stringify(appCapabilities()) }
    expect((await jsonRequest(server, "/v1/screen-sharing", request)).status).toBe(401)
    for (const browserHeader of [
      { Origin: "https://example.com" },
      { "Sec-Fetch-Site": "same-origin" }
    ]) {
      expect(
        (
          await jsonRequest(server, "/v1/screen-sharing", {
            ...request,
            headers: { Authorization: `Bearer ${token}`, ...browserHeader }
          })
        ).status
      ).toBe(403)
    }
    expect(helper).not.toHaveBeenCalled()
    expect(
      (
        await jsonRequest(server, "/v1/screen-sharing", {
          ...request,
          headers: { Authorization: `Bearer ${token}` }
        })
      ).body
    ).toEqual(reply)
    expect(helper).toHaveBeenCalledOnce()
  })

  it("advertises availability and passes an app's start, heartbeat and stop transiently", async () => {
    const helper = vi.fn(async (request: ScreenSharingRequest) => ({
      ...reply,
      status: request.operation === "start" ? "connecting" : "stopped",
      media: grant
    }))
    const { server, request, post } = await fixture(helper)
    expect((await jsonRequest(server, "/v1/info")).body).toMatchObject({
      features: expect.arrayContaining(["screen-sharing-v1"])
    })
    const response = await fetch(`${server.url}/v1/screen-sharing`, {
      method: "POST",
      body: JSON.stringify(request)
    })
    expect(response.status).toBe(200)
    expect(response.headers.get("cache-control")).toBe("no-store")
    expect(await response.json()).toMatchObject({ status: "connecting", media: grant })
    expect(helper).toHaveBeenLastCalledWith(request)
    const { app: _, intent: __, proof: ___, ...stable } = request
    expect((await post({ ...stable, operation: "heartbeat", session })).status).toBe(200)
    expect((await post({ ...stable, operation: "stop", session })).status).toBe(200)
  })

  it("rejects malformed, oversized, or incompatible requests before invoking the helper", async () => {
    const helper = vi.fn(async () => reply)
    const { server, request, post } = await fixture(helper)
    expect((await jsonRequest(server, "/v1/screen-sharing")).status).toBe(405)
    expect(
      (
        await jsonRequest(server, "/v1/screen-sharing", {
          method: "POST",
          body: "{"
        })
      ).status
    ).toBe(400)
    expect((await post({ ...request, version: 2 })).status).toBe(400)
    for (const field of ["workspaceId", "paneId", "viewerId"]) {
      expect((await post({ ...request, [field]: "invalid" })).status).toBe(400)
    }
    for (const change of [{ media: undefined }, { displayId: "invalid" }])
      expect((await post({ ...request, ...change })).status).toBe(400)
    expect((await post({ ...request, displayId: "x".repeat(301 * 1024) })).status).toBe(413)
    const { engine: _, media: __, app: ___, intent: ____, proof: _____, ...webRTC } = request
    const oldViewer = await post({ ...webRTC, offer: "v=0\r\na=fingerprint:sha-256 fixture\r\n" })
    expect(oldViewer.status).toBe(400)
    expect(oldViewer.body).toMatchObject({ error: expect.stringContaining("Update Codevisor") })
    expect(helper).not.toHaveBeenCalled()
  })
  it("returns actionable errors for an absent, incompatible or failed native helper", async () => {
    const { services } = await makeServices()
    const server = await startWithApp(services)
    expect((await jsonRequest(server, "/v1/info")).body).toMatchObject({
      features: expect.not.arrayContaining(["screen-sharing-v1"])
    })
    expect(
      (
        await jsonRequest(server, "/v1/screen-sharing", {
          method: "POST",
          body: JSON.stringify(appCapabilities())
        })
      ).status
    ).toBe(501)
    const helper = vi.fn(async (): Promise<unknown> => ({ version: 2 }))
    const { post } = await fixture(helper)
    expect((await post(appCapabilities())).status).toBe(503)
    helper.mockRejectedValueOnce(new Error("secret helper path and token"))
    const failed = await post(appCapabilities())
    expect(failed.status).toBe(503)
    expect(JSON.stringify(failed.body)).not.toContain("secret")
    expect(failed.body).toMatchObject({
      error: expect.stringContaining("Open or update Codevisor")
    })
  })

  it("tells a host that timed out or stopped apart from one that can't be reached", async () => {
    const helper = vi.fn(async (): Promise<unknown> => ({ version: 2 }))
    const { post } = await fixture(helper)
    helper.mockRejectedValueOnce(new Error("Screen Sharing host timed out."))
    const timedOut = await post(appCapabilities())
    expect(timedOut.status).toBe(504)
    expect(timedOut.body).toMatchObject({
      error: expect.stringContaining("screen capture may be stuck")
    })
    helper.mockRejectedValueOnce(new Error("Computer Use helper timed out"))
    expect((await post(appCapabilities())).status).toBe(504)
    helper.mockRejectedValueOnce(new Error("Screen Sharing host is stopped."))
    const stopped = await post(appCapabilities())
    expect(stopped.status).toBe(503)
    expect(stopped.body).toMatchObject({
      error: expect.stringContaining("Open a Codevisor window")
    })
    helper.mockRejectedValueOnce(new Error("Screen Sharing host timed out. /Users/secret"))
    const other = await post(appCapabilities())
    expect(other.body).toMatchObject({
      error: expect.stringContaining("Open or update Codevisor")
    })
    expect(JSON.stringify(other.body)).not.toContain("secret")
    helper.mockRejectedValueOnce("Screen Sharing host timed out.")
    expect((await post(appCapabilities())).status).toBe(503)
  })
})
