import { randomUUID } from "node:crypto"

import type { ScreenSharingRequest } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import { jsonRequest, makeServices, run, runningServers, startWithApp } from "./test-support.js"

const capabilities = (): ScreenSharingRequest => ({
  version: 1,
  operation: "capabilities",
  workspaceId: randomUUID(),
  paneId: randomUUID(),
  viewerId: randomUUID()
})
const offer = "v=0\r\na=fingerprint:sha-256 fixture\r\n"
const reply = { version: 1, status: "available", displays: [] }

const fixture = async (
  screenSharing: (request: ScreenSharingRequest) => Promise<unknown> = async () => reply
) => {
  const { services } = await makeServices()
  const server = await startWithApp(services, undefined, { screenSharing })
  runningServers.push(server)
  const project = await run(services.db.createProject({ folderPath: "/fixture/screen-sharing" }))
  const workspace = await run(
    services.db.upsertWorkspace({ projectId: project.id, name: "Sharing", hasCustomName: false })
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
    offer
  }
  const post = (body: unknown = request, headers: Record<string, string> = {}) =>
    jsonRequest(server, "/v1/screen-sharing", {
      method: "POST",
      body: JSON.stringify(body),
      headers
    })
  return { server, services, project, workspace, pane, request, post }
}

describe("native Screen Sharing signaling", () => {
  it("requires machine authentication and rejects browser-originated requests", async () => {
    const helper = vi.fn(async () => reply)
    const { services } = await makeServices()
    const token = await run(services.db.issuePairingToken)
    const server = await startWithApp(services, undefined, {
      screenSharing: helper,
      auth: { allowLocalhostWithoutAuth: false, requireBearerToken: true }
    })
    runningServers.push(server)
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

  it("advertises availability, passes a valid offer transiently, and permits stop after pane deletion", async () => {
    const helper = vi.fn(async (request: ScreenSharingRequest) => ({
      ...reply,
      status: request.operation === "start" ? "connecting" : "stopped",
      answer: "fixture answer"
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
    expect(await response.json()).toMatchObject({ status: "connecting", answer: "fixture answer" })
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
      (await jsonRequest(server, "/v1/screen-sharing", { method: "POST", body: "{" })).status
    ).toBe(400)
    expect((await post({ ...request, version: 2 })).status).toBe(400)
    for (const field of ["workspaceId", "paneId", "viewerId"]) {
      expect((await post({ ...request, [field]: "invalid" })).status).toBe(400)
    }
    for (const change of [
      { offer: undefined },
      { offer: "x".repeat(256 * 1024 + 1) },
      { offer: "v=0" },
      { displayId: undefined },
      { displayId: "invalid" }
    ]) {
      expect((await post({ ...request, ...change })).status).toBe(400)
      expect((await post({ ...request, operation: "restart", ...change })).status).toBe(400)
    }
    expect((await post({ ...request, offer: "x".repeat(301 * 1024) })).status).toBe(413)
    expect(helper).not.toHaveBeenCalled()
  })

  it("returns short-lived connectivity credentials without persisting them or allowing caching", async () => {
    const connectivity = {
      servers: [
        {
          urls: ["turn:relay.example.test:3478"],
          username: "fixture-viewer",
          credential: "ephemeral-password"
        }
      ],
      relayOnly: true,
      expiresAt: 1700000300
    }
    const { server, request, services, pane } = await fixture(async () => ({
      ...reply,
      connectivity
    }))
    const response = await fetch(`${server.url}/v1/screen-sharing`, {
      method: "POST",
      body: JSON.stringify({ ...request, operation: "capabilities" })
    })
    expect(response.headers.get("cache-control")).toBe("no-store")
    expect(await response.json()).toEqual({ ...reply, connectivity })
    expect((await run(services.db.listWorkspacePanes)).find((item) => item.id === pane.id)).toEqual(
      pane
    )
  })

  it("validates workspace, pane, provider and archive state for start and heartbeat", async () => {
    const helper = vi.fn(async () => reply)
    const { services, project, workspace, pane, request, post } = await fixture(helper)
    expect((await post({ ...request, workspaceId: randomUUID() })).status).toBe(404)
    expect((await post({ ...request, paneId: randomUUID() })).status).toBe(404)
    const second = await run(
      services.db.upsertWorkspace({ projectId: project.id, name: "Other", hasCustomName: false })
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

  it("returns actionable errors for an absent, incompatible or failed native helper", async () => {
    const { services } = await makeServices()
    const server = await startWithApp(services)
    runningServers.push(server)
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
  })

  it("streams a chat's Computer Use window only to that chat's pane", async () => {
    const helper = vi.fn(async (request: ScreenSharingRequest) => ({
      ...reply,
      status: request.operation === "start" ? "connecting" : "viewing",
      answer: "fixture answer"
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

    // Another chat's agent, a display pane, or a malformed target are refused.
    expect((await post({ ...target, displayId: `computer-use:${other.id}` })).status).toBe(404)
    expect((await post({ ...request, displayId: target.displayId })).status).toBe(404)
    for (const displayId of ["computer-use:", "computer-use:invalid", "window:1"]) {
      expect((await post({ ...target, displayId })).status).toBe(400)
      expect((await post({ ...target, operation: "heartbeat", displayId })).status).toBe(400)
    }
    // A chat pane cannot address a display.
    expect((await post({ ...target, displayId: randomUUID() })).status).toBe(404)
    expect(helper).toHaveBeenCalledTimes(5)
  })
})
