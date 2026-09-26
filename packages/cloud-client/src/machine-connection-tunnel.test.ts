import { CLOUD_PROTOCOL_VERSION } from "@codevisor/api"
import type { MachineToHub } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import { CloudMachineConnection } from "./index.js"
import { credentials, FakeSocket } from "./machine-connection-test-support.js"

// The machine's hub connection as the tunnel's control plane: registering the
// endpoint, receiving relay config and vouched devices, reporting addresses.

const endpointId = "a".repeat(64)

const tunnelConnection = (releaseChannel?: () => "stable" | "alpha" | undefined) => {
  const sockets: FakeSocket[] = []
  const headers: Record<string, string>[] = []
  const configs: unknown[] = []
  const peers: unknown[] = []
  const connection = new CloudMachineConnection({
    credentials,
    device: { name: "vps", ...(releaseChannel === undefined ? {} : { releaseChannel }) },
    socketFactory: (_url, requestHeaders) => {
      headers.push(requestHeaders)
      const socket = new FakeSocket()
      sockets.push(socket)
      return socket
    },
    channelHandlers: {},
    tunnelEndpointId: endpointId,
    onTunnelConfig: (config) => configs.push(config),
    onPeerDevices: (devices) => peers.push(devices),
    scheduleReconnect: vi.fn(),
    scheduleTimeout: () => () => undefined
  })
  connection.start()
  const socket = sockets[0]!
  socket.onopen?.()
  return { connection, socket, headers, configs, peers }
}

describe("tunnel control plane on the machine connection", () => {
  it("registers the endpoint in the connect headers and hello", () => {
    const { socket, headers } = tunnelConnection()
    expect(headers[0]).toEqual({
      "x-api-key": "api-key",
      "x-codevisor-tunnel-endpoint": endpointId
    })
    const hello = socket.sent[0] as Extract<MachineToHub, { t: "hello" }>
    expect(hello.device.tunnelEndpointId).toBe(endpointId)
  })

  it("reports the machine's release channel in each hello, when it knows it", () => {
    const hello = (socket: FakeSocket) =>
      (socket.sent[0] as Extract<MachineToHub, { t: "hello" }>).device.releaseChannel
    expect(hello(tunnelConnection(() => "alpha").socket)).toBe("alpha")
    expect(hello(tunnelConnection(() => undefined).socket)).toBeUndefined()
    expect(hello(tunnelConnection().socket)).toBeUndefined()
  })

  it("surfaces each welcome's relay map and rollout", () => {
    const { socket, configs } = tunnelConnection()
    const relays = [{ url: "https://relay-a.test", quicPort: 7842 }]
    socket.receive({
      t: "welcome",
      protocol: CLOUD_PROTOCOL_VERSION,
      connectionId: "c1",
      relays,
      tunnel: "on"
    })
    // An older hub sends neither field: no relays, tunnel off.
    socket.receive({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION, connectionId: "c2" })
    expect(configs).toEqual([
      { relays, enabled: true },
      { relays: [], enabled: false }
    ])
  })

  it("hands vouched devices to the tunnel", () => {
    const { socket, peers } = tunnelConnection()
    const devices = [{ deviceId: "app-1", publicKey: "k", endpointId: "e" }]
    socket.receive({ t: "peer-devices", devices })
    expect(peers).toEqual([devices])
  })

  it("reports addresses only while connected", () => {
    const { connection, socket } = tunnelConnection()
    const tunnel = { endpointId, directAddrs: ["192.168.1.4:41641"] }
    expect(connection.sendTunnelAddr(tunnel)).toBe(false)

    socket.receive({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION, connectionId: "c1" })
    expect(connection.sendTunnelAddr(tunnel)).toBe(true)
    expect(socket.sent.at(-1)).toEqual({ t: "tunnel-addr", tunnel })

    socket.sendError = new Error("socket gone")
    expect(connection.sendTunnelAddr(tunnel)).toBe(false)
  })
})
