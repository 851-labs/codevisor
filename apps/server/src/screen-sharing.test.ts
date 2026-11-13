import { randomUUID } from "node:crypto"

import type { ScreenSharingRequest } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

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
const grant = {
  endpointId: "b".repeat(64),
  directAddrs: ["192.168.1.3:4433"],
  token: "t".repeat(64)
}

const fixture = async (
  screenSharing: (request: ScreenSharingRequest) => Promise<unknown> = async () => reply
) => {
  const { services } = await makeServices()
  const server = await startWithApp(services, undefined, { screenSharing })
  const project = await run(services.db.createProject({ folderPath: "/fixture/screen-sharing" }))
  const workspace = await run(
    services.db.upsertWorkspace({
      projectId: project.id,
      name: "Sharing",
      hasCustomName: false
    })
  )
  const pane = await run(
    services.db.upsertWorkspacePane(workspace.id, {
      id: randomUUID(),
      providerId: "codevisor",
      paneType: "screen-sharing",
      title: "Screen Sharing"
    })
  )
  const request: ScreenSharingRequest = {
    ...capabilities(),
    operation: "start",
    workspaceId: workspace.id,
    paneId: pane.id,
    displayId: randomUUID(),
    engine: "v2",
    media
  }
  const post = (body: unknown = request, headers: Record<string, string> = {}) =>
    jsonRequest(server, "/v1/screen-sharing", {
      method: "POST",
      body: JSON.stringify(body),
      headers
    })
  return { server, services, project, workspace, pane, request, post }
}

describe("Screen Sharing engine v2 signaling", () => {
  it("starts v2, forwards the viewer's chroma and returns the host's media grant", async () => {
    const helper = vi.fn(async (request: ScreenSharingRequest) => ({
      ...reply,
      status: "connecting",
      engines: ["v2"],
      ...(request.engine === "v2" ? { media: grant } : {})
    }))
    const { request, post } = await fixture(helper)
    const v2 = { ...request, chroma: "420" }
    for (const operation of ["start", "restart"])
      expect((await post({ ...v2, operation })).body).toMatchObject({
        engines: ["v2"],
        media: grant
      })
    expect(helper).toHaveBeenCalledWith(
      expect.objectContaining({ engine: "v2", media, chroma: "420" })
    )
  })

  it("rejects a start without engine v2 or a valid viewer address before invoking the helper", async () => {
    const helper = vi.fn(async () => reply)
    const { request: v2, post } = await fixture(helper)
    for (const change of [
      { engine: undefined },
      { media: undefined },
      { media: { ...media, endpointId: "not-hex" } },
      { media: { ...media, directAddrs: Array.from({ length: 33 }, () => "10.0.0.1:1") } },
      { media: { ...media, directAddrs: ["x".repeat(65)] } },
      { media: { ...media, relayUrl: `https://${"r".repeat(512)}` } },
      { engine: "v3", media },
      { media, chroma: "422" }
    ])
      expect((await post({ ...v2, ...change })).status).toBe(400)
    expect(helper).not.toHaveBeenCalled()
  })
})

describe("app-owned Screen Sharing sessions", () => {
  const app = { key: media.endpointId, name: "Alexandru's MacBook Pro" }
  const appStart = (): ScreenSharingRequest => ({
    ...capabilities(),
    operation: "start",
    displayId: randomUUID(),
    engine: "v2",
    media,
    app,
    intent: "open"
  })

  it("serves an app's desktop session without a workspace or pane, and a request without the app as before", async () => {
    const helper = vi.fn(async () => reply)
    const { post } = await fixture(helper)
    const start = appStart()
    const { displayId: _, ...anyDisplay } = start
    for (const request of [
      start,
      anyDisplay,
      { ...start, operation: "restart" },
      { ...start, operation: "heartbeat" },
      { ...anyDisplay, operation: "heartbeat" },
      { ...start, operation: "stop" }
    ])
      expect((await post(request)).status).toBe(200)
    expect(helper).toHaveBeenCalledTimes(6)
    expect(helper).toHaveBeenCalledWith(start)

    const { app: __, intent: ___, ...stable } = start
    expect((await post(stable)).status).toBe(404)
    expect((await post({ ...stable, operation: "heartbeat" })).status).toBe(404)
    expect((await post({ ...stable, displayId: undefined })).status).toBe(400)
    expect(helper).toHaveBeenCalledTimes(6)
  })

  it("still requires the pane for an app's Computer Use and Simulator streams", async () => {
    const helper = vi.fn(async () => reply)
    const { post } = await fixture(helper)
    for (const displayId of [`computer-use:${randomUUID()}`, `simulator:${randomUUID()}`]) {
      expect((await post({ ...appStart(), displayId })).status).toBe(404)
      expect((await post({ ...appStart(), operation: "heartbeat", displayId })).status).toBe(404)
    }
    expect(helper).not.toHaveBeenCalled()
  })

  it("rejects a malformed app, a start under another key, and a start that doesn't say open or attach", async () => {
    const helper = vi.fn(async () => reply)
    const { post } = await fixture(helper)
    for (const change of [
      { app: { ...app, key: "not-hex" } },
      { app: { ...app, name: " " } },
      { app: { ...app, name: "n".repeat(65) } },
      { app: { ...app, key: "c".repeat(64) } },
      { intent: undefined },
      { intent: "steal" },
      { displayId: "invalid" }
    ])
      expect((await post({ ...appStart(), ...change })).status).toBe(400)
    expect(
      (await post({ ...appStart(), operation: "heartbeat", app: { key: "x", name: "n" } })).status
    ).toBe(400)
    expect(helper).not.toHaveBeenCalled()
    expect(
      (await post({ ...appStart(), app: { ...app, key: app.key.toUpperCase() }, intent: "attach" }))
        .status
    ).toBe(200)
  })

  it("passes on why the host refused or ended, who holds the session, what it shares and what it can do", async () => {
    const display = { id: randomUUID(), name: "Built-in Display", width: 3024, height: 1964 }
    const refused = {
      ...reply,
      status: "busy",
      message: "This Mac is already sharing with another viewer.",
      reason: "in-use",
      holderName: "Alexandru's iPhone",
      abilities: ["app-sessions"]
    }
    const viewing = {
      ...reply,
      status: "viewing",
      display,
      displays: [display],
      reason: "a-later-reason"
    }
    const helper = vi.fn(async (): Promise<unknown> => ({ ...refused, laterField: true }))
    const { post } = await fixture(helper)
    expect((await post({ ...appStart(), intent: "attach" })).body).toEqual(refused)
    helper.mockResolvedValueOnce(viewing)
    expect((await post({ ...appStart(), operation: "heartbeat" })).body).toEqual(viewing)
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
    const request = { method: "POST", body: JSON.stringify(capabilities()) }
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

  it("advertises availability, passes a valid start transiently, and permits stop after pane deletion", async () => {
    const helper = vi.fn(async (request: ScreenSharingRequest) => ({
      ...reply,
      status: request.operation === "start" ? "connecting" : "stopped",
      media: grant
    }))
    const { server, services, workspace, pane, request, post } = await fixture(helper)
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
    expect((await post({ ...request, operation: "restart" })).status).toBe(200)
    expect((await post({ ...request, operation: "heartbeat" })).status).toBe(200)
    expect((await run(services.db.listWorkspacePanes)).find((item) => item.id === pane.id)).toEqual(
      pane
    )
    await run(services.db.deleteWorkspacePane(workspace.id, pane.id))
    expect((await post({ ...request, operation: "heartbeat" })).status).toBe(404)
    expect((await post({ ...request, operation: "restart" })).status).toBe(404)
    expect((await post({ ...request, operation: "stop" })).status).toBe(200)
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
    for (const change of [
      { media: undefined },
      { displayId: undefined },
      { displayId: "invalid" }
    ]) {
      expect((await post({ ...request, ...change })).status).toBe(400)
      expect((await post({ ...request, operation: "restart", ...change })).status).toBe(400)
    }
    expect((await post({ ...request, displayId: "x".repeat(301 * 1024) })).status).toBe(413)
    const { engine: _, media: __, ...webRTC } = request
    const oldViewer = await post({ ...webRTC, offer: "v=0\r\na=fingerprint:sha-256 fixture\r\n" })
    expect(oldViewer.status).toBe(400)
    expect(oldViewer.body).toMatchObject({ error: expect.stringContaining("Update Codevisor") })
    expect(helper).not.toHaveBeenCalled()
  })

  it("validates workspace, pane, provider and archive state for start and heartbeat", async () => {
    const helper = vi.fn(async () => reply)
    const { services, project, workspace, pane, request, post } = await fixture(helper)
    expect((await post({ ...request, workspaceId: randomUUID() })).status).toBe(404)
    expect((await post({ ...request, paneId: randomUUID() })).status).toBe(404)
    const second = await run(
      services.db.upsertWorkspace({
        projectId: project.id,
        name: "Other",
        hasCustomName: false
      })
    )
    expect((await post({ ...request, workspaceId: second.id })).status).toBe(404)
    await run(
      services.db.upsertWorkspacePane(workspace.id, {
        id: pane.id,
        title: "Screen Sharing",
        providerId: "plugin",
        paneType: "screen-sharing"
      })
    )
    expect((await post()).status).toBe(404)
    await run(
      services.db.upsertWorkspacePane(workspace.id, {
        id: pane.id,
        title: "Screen Sharing",
        providerId: "codevisor",
        paneType: "browser"
      })
    )
    expect((await post()).status).toBe(404)
    await run(
      services.db.upsertWorkspacePane(workspace.id, {
        id: pane.id,
        title: "Screen Sharing",
        providerId: "codevisor",
        paneType: "screen-sharing"
      })
    )
    await run(services.db.updateWorkspace(workspace.id, { isArchived: true }))
    expect((await post()).status).toBe(404)
    expect(helper).not.toHaveBeenCalled()
  })

  it("streams the desktop to an inspector's hidden machine-desktop pane", async () => {
    const helper = vi.fn(async () => reply)
    const { services, workspace, pane, post } = await fixture(helper)
    await run(
      services.db.upsertWorkspacePane(workspace.id, {
        id: pane.id,
        title: "Desktop",
        providerId: "codevisor",
        paneType: "machine-desktop"
      })
    )
    expect((await post()).status).toBe(200)
    expect(helper).toHaveBeenCalledOnce()
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
          body: JSON.stringify(capabilities())
        })
      ).status
    ).toBe(501)
    const helper = vi.fn(async (): Promise<unknown> => ({ version: 2 }))
    const { post } = await fixture(helper)
    expect((await post(capabilities())).status).toBe(503)
    helper.mockRejectedValueOnce(new Error("secret helper path and token"))
    const failed = await post(capabilities())
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
    const timedOut = await post(capabilities())
    expect(timedOut.status).toBe(504)
    expect(timedOut.body).toMatchObject({
      error: expect.stringContaining("screen capture may be stuck")
    })
    helper.mockRejectedValueOnce(new Error("Computer Use helper timed out"))
    expect((await post(capabilities())).status).toBe(504)
    helper.mockRejectedValueOnce(new Error("Screen Sharing host is stopped."))
    const stopped = await post(capabilities())
    expect(stopped.status).toBe(503)
    expect(stopped.body).toMatchObject({
      error: expect.stringContaining("Open a Codevisor window")
    })
    helper.mockRejectedValueOnce(new Error("Screen Sharing host timed out. /Users/secret"))
    const other = await post(capabilities())
    expect(other.body).toMatchObject({
      error: expect.stringContaining("Open or update Codevisor")
    })
    expect(JSON.stringify(other.body)).not.toContain("secret")
    helper.mockRejectedValueOnce("Screen Sharing host timed out.")
    expect((await post(capabilities())).status).toBe(503)
  })

  it("streams a chat's Computer Use window only to that chat's pane", async () => {
    const helper = vi.fn(async (request: ScreenSharingRequest) => ({
      ...reply,
      status: request.operation === "start" ? "connecting" : "viewing",
      ...(request.operation === "start" ? { media: grant } : {})
    }))
    const { server, services, project, workspace, request, post } = await fixture(helper)
    expect((await jsonRequest(server, "/v1/info")).body).toMatchObject({
      features: expect.arrayContaining(["computer-use-stream-v1"])
    })
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    const other = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    const chatPane = await run(
      services.db.upsertWorkspacePane(workspace.id, {
        id: randomUUID(),
        providerId: "codevisor",
        paneType: "chat",
        title: "Chat",
        resourceKind: "session",
        resourceId: session.id
      })
    )
    const target = {
      ...request,
      paneId: chatPane.id,
      displayId: `computer-use:${session.id.toUpperCase()}`
    }
    for (const operation of ["capabilities", "start", "restart", "heartbeat", "stop"] as const) {
      expect((await post({ ...target, operation })).status).toBe(200)
    }
    expect(helper).toHaveBeenCalledTimes(5)

    expect((await post({ ...target, displayId: `computer-use:${other.id}` })).status).toBe(404)
    expect((await post({ ...request, displayId: target.displayId })).status).toBe(404)
    for (const displayId of ["computer-use:", "computer-use:invalid", "window:1"]) {
      expect((await post({ ...target, displayId })).status).toBe(400)
      expect((await post({ ...target, operation: "heartbeat", displayId })).status).toBe(400)
    }
    expect((await post({ ...target, displayId: randomUUID() })).status).toBe(404)
    expect(helper).toHaveBeenCalledTimes(5)
  })
})
