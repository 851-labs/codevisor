import { once } from "node:events"

import { describe, expect, it } from "vitest"
import { WebSocket } from "ws"

import { jsonRequest, start } from "../test-support.js"

const workspaceId = "3e6c0a52-5b1f-4d4e-9a0c-2f7d8e1b4c11"

describe("client control routes", () => {
  it("round-trips context and navigation through a connected native window", async () => {
    const { server } = await start()
    const socket = new WebSocket(`${server.url.replace("http", "ws")}/v1/clients/window/socket`)
    try {
      await once(socket, "open")
      socket.send(JSON.stringify({ type: "hello", name: "Test window", platform: "macos" }))
      const pong = once(socket, "pong")
      socket.ping()
      await pong
      const probe = once(socket, "message")
      const listing = jsonRequest(server, "/v1/clients?originClientId=WINDOW")
      const [probeRaw] = await probe
      const probeRequest = JSON.parse(String(probeRaw))
      expect(probeRequest.method).toBe("context")
      socket.send(
        JSON.stringify({
          type: "response",
          requestId: probeRequest.requestId,
          context: { isActive: false, workspaces: [] }
        })
      )
      expect(await listing).toEqual({
        status: 200,
        body: [
          {
            id: "window",
            clientId: "window",
            name: "Test window",
            platform: "macos",
            machine: { id: "server-a", name: expect.any(String) },
            online: true,
            isOrigin: true,
            isActive: false,
            viewing: {}
          }
        ]
      })
      const commands = [
        { method: "context", body: undefined },
        { method: "navigate", body: { workspaceId } },
        { method: "page", body: { page: "settings", section: "plugins" } },
        {
          method: "layout",
          body: {
            workspaceId: "workspace",
            action: {
              kind: "resize",
              tabId: "tab",
              branchPath: [],
              fractions: [0.4, 0.6],
              expectedChildren: [["left"], ["right"]]
            }
          }
        },
        ...[{}, { focus: false }, { focus: true }].map((options) => ({
          method: "layout",
          body: { workspaceId: "workspace", action: { kind: "new_tab" }, ...options }
        })),
        { method: "window", body: { action: "frame", x: 20, y: 30, width: 1000, height: 800 } }
      ]
      for (const { method, body } of commands) {
        const command = once(socket, "message")
        const result = jsonRequest(
          server,
          `/v1/clients/window/${method}`,
          body ? { method: "POST", body: JSON.stringify(body) } : {}
        )
        const [raw] = await command
        const request = JSON.parse(String(raw))
        expect(request.method).toBe(method)
        if (body) expect(request[method === "navigate" ? "navigation" : method]).toEqual(body)
        socket.send(
          JSON.stringify({
            type: "response",
            requestId: request.requestId,
            context: { isActive: true, workspaces: [], workspaceId: "workspace" }
          })
        )
        expect(await result).toMatchObject({ status: 200, body: { workspaceId: "workspace" } })
      }
      for (const method of ["page", "layout", "window"]) {
        expect(await jsonRequest(server, `/v1/clients/window/${method}`)).toMatchObject({
          status: 404
        })
        expect(
          await jsonRequest(server, `/v1/clients/window/${method}`, { method: "POST", body: "{}" })
        ).toMatchObject({ status: 400 })
      }
      expect(await jsonRequest(server, "/v1/clients/missing/context")).toEqual({
        status: 404,
        body: {
          error: "Client is not connected. Discover clients again.",
          code: "client_unavailable",
          details: { clientId: "missing", phase: "before-send" }
        }
      })
      expect(
        await jsonRequest(server, "/v1/clients/window/navigate", { method: "POST", body: "{}" })
      ).toMatchObject({ status: 400 })
      expect(
        await jsonRequest(server, "/v1/clients/window/navigate", {
          method: "POST",
          body: JSON.stringify({
            workspaceId,
            destination: { kind: "pane", id: "notes-pane" }
          })
        })
      ).toMatchObject({ status: 400 })
      expect(
        await jsonRequest(server, "/v1/clients/window/layout", {
          method: "POST",
          body: JSON.stringify({
            workspaceId: "workspace",
            action: { kind: "new_tab" },
            focus: "false"
          })
        })
      ).toMatchObject({ status: 400 })
      expect(await jsonRequest(server, "/v1/clients/window/unknown")).toMatchObject({ status: 404 })
      expect(await jsonRequest(server, "/v1/clients", { method: "POST" })).toMatchObject({
        status: 404
      })
    } finally {
      const closed = once(socket, "close")
      socket.close()
      await closed
    }
  })

  it("requires the same authorization as other server APIs", async () => {
    const { server } = await start({ allowLocalhostWithoutAuth: false, requireBearerToken: true })
    expect(await jsonRequest(server, "/v1/clients")).toMatchObject({ status: 401 })
    const socket = new WebSocket(
      `${server.url.replace("http", "ws")}/v1/clients/unauthorized/socket`
    )
    const error = await new Promise<Error>((resolve) => socket.once("error", resolve))
    expect(error.message).toContain("401")
  })
})
