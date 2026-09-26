import { afterEach, describe, expect, it } from "vitest"

import {
  ALPN_CHANNELS,
  defaultAddonPath,
  loadNet,
  MESSAGE_BINARY,
  MESSAGE_TEXT,
  type TunnelEndpoint
} from "./index.js"

// Real native boundary: two endpoints on loopback, no relay. The Rust crate's
// own tests cover relays and media flows; this proves the binding and the
// TypeScript types agree.
describe("codevisor-net addon", () => {
  const endpoints: TunnelEndpoint[] = []
  afterEach(async () => {
    await Promise.all(endpoints.splice(0).map((endpoint) => endpoint.close()))
  })

  const bind = async (): Promise<TunnelEndpoint> => {
    const net = loadNet()
    const endpoint = await net.TunnelEndpoint.bind({
      secretKeyHex: net.generateSecretKeyHex(),
      relays: [],
      bindAddrs: ["127.0.0.1:0"],
      pathPolicy: "direct-only",
      alpns: [ALPN_CHANNELS]
    })
    endpoints.push(endpoint)
    return endpoint
  }

  it("derives endpoint ids from secret keys", () => {
    const net = loadNet()
    const secret = net.generateSecretKeyHex()
    expect(secret).toMatch(/^[0-9a-f]{64}$/)
    expect(net.endpointIdForSecretKey(secret)).toMatch(/^[0-9a-f]{64}$/)
  })

  it("carries text and binary messages both ways over a direct path", async () => {
    const [server, client] = [await bind(), await bind()]
    const accepted = (async () => {
      const connection = await server.accept()
      const stream = await connection!.acceptMessageStream()
      for (;;) {
        const message = await stream.recv()
        if (message === null) return connection!
        await stream.send(message.kind, message.payload)
      }
    })()

    const connection = await client.connect(server.addr(), ALPN_CHANNELS)
    expect(connection.remoteId()).toBe(server.endpointId())
    expect(connection.alpn()).toBe(ALPN_CHANNELS)
    const stream = await connection.openMessageStream()
    await stream.send(MESSAGE_TEXT, Buffer.from('{"t":"hello"}'))
    await stream.send(MESSAGE_BINARY, Buffer.alloc(300_000, 9))
    const text = await stream.recv()
    expect(text?.kind).toBe(MESSAGE_TEXT)
    expect(text?.payload.toString()).toBe('{"t":"hello"}')
    const binary = await stream.recv()
    expect(binary?.kind).toBe(MESSAGE_BINARY)
    expect(binary?.payload.equals(Buffer.alloc(300_000, 9))).toBe(true)
    expect(connection.paths().every((path) => !path.isRelay)).toBe(true)

    await stream.finish()
    const serverConnection = await accepted
    expect(serverConnection.remoteId()).toBe(client.endpointId())
  })

  it("explains how to build a missing addon", () => {
    expect(() => loadNet("/nonexistent/codevisor_net.node")).toThrow(
      /net-artifact\.mjs ensure-node/
    )
  })

  it("prefers an explicit addon path from the environment", () => {
    expect(defaultAddonPath({ CODEVISOR_NET_ADDON: "/opt/codevisor/net.node" })).toBe(
      "/opt/codevisor/net.node"
    )
    expect(defaultAddonPath({})).toMatch(/native\/[a-z0-9]+-[a-z0-9]+\/codevisor_net\.node$/)
  })
})
