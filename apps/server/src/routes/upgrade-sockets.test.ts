import { IncomingMessage } from "node:http"
import { Socket } from "node:net"

import { describe, expect, it, vi } from "vitest"
import { WebSocketServer } from "ws"

import { ClientControlBroker } from "../infra/client-control.js"
import { defaultServerConfig, makeEventFanout } from "../server.js"
import { makeServices, run } from "../test-support.js"
import { handleUpgrade } from "./events.js"
import { VNC_SOCKET_PATH } from "./screen-sharing-vnc.js"

const cloudWithoutDirect = {
  deviceId: () => "device-a",
  state: () => "connected" as const,
  managedBy: () => "external" as const,
  connect: () => Promise.resolve("device-a"),
  disconnect: () => Promise.resolve({ removedFromAccount: true })
}

describe("websocket upgrades for unavailable sockets", () => {
  it.each([
    ["a direct socket without a cloud identity", "GET", "/v1/direct"],
    ["a live preview socket with no session", "GET", "/v1/live-preview/socket"],
    ["a live preview socket without MCP", "GET", "/v1/live-preview/socket?sessionId=s1"],
    ["a screen sharing socket while screen sharing is off", "GET", VNC_SOCKET_PATH],
    ["a browser host socket without MCP", "GET", "/v1/browser-use/host/socket"],
    ["a client socket opened with POST", "POST", "/v1/clients/c1/socket"],
    ["a session event socket opened with POST", "POST", "/v1/sessions/s1/events/socket"]
  ])("drops %s without upgrading it", async (_name, method, url) => {
    const { services } = await makeServices("server-a")
    const { mcp: _mcp, ...servicesWithoutMcp } = services
    const request = Object.assign(new IncomingMessage(new Socket()), { method, url })
    const socket = new Socket()
    const webSocketServer = new WebSocketServer({ noServer: true })
    const upgrade = vi.spyOn(webSocketServer, "handleUpgrade")
    await handleUpgrade(
      servicesWithoutMcp,
      defaultServerConfig({
        bootId: "test-boot",
        id: "server-a",
        port: 0,
        cloud: cloudWithoutDirect
      }),
      await run(makeEventFanout),
      request,
      socket,
      Buffer.alloc(0),
      webSocketServer,
      new ClientControlBroker()
    )
    expect(upgrade).not.toHaveBeenCalled()
    expect(socket.destroyed).toBe(true)
  })
})
