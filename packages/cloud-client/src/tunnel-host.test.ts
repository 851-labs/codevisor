import type { CloudVouchedDevice } from "@codevisor/api"
import type {
  EndpointOptions,
  TunnelAddr,
  TunnelConnection,
  TunnelEndpoint,
  TunnelMessage,
  TunnelMessageStream
} from "@codevisor/net"
import { describe, expect, it, vi } from "vitest"

import { makePeerKeyPinStore } from "./peer-pins.js"
import {
  admitTunnelHello,
  MachineTunnel,
  TUNNEL_ALPN_CHANNELS,
  TUNNEL_ALPN_MEDIA,
  tunnelSocket
} from "./tunnel-host.js"

/// Resolvable queue standing in for the native async calls.
class Pending<Item> {
  #items: Item[] = []
  #waiters: ((item: Item) => void)[] = []
  push(item: Item): void {
    const waiter = this.#waiters.shift()
    if (waiter === undefined) this.#items.push(item)
    else waiter(item)
  }
  next(): Promise<Item> {
    const item = this.#items.shift()
    if (item !== undefined) return Promise.resolve(item)
    return new Promise((resolve) => this.#waiters.push(resolve))
  }
}

type Outcome<Value> = { value: Value } | { error: Error }
const settle = async <Value>(queue: Pending<Outcome<Value>>): Promise<Value> => {
  const outcome = await queue.next()
  if ("error" in outcome) throw outcome.error
  return outcome.value
}

class FakeStream implements TunnelMessageStream {
  sent: { kind: number; payload: string }[] = []
  incoming = new Pending<Outcome<TunnelMessage | null>>()
  sendError: Error | undefined
  async send(kind: number, payload: Buffer): Promise<void> {
    if (this.sendError !== undefined) throw this.sendError
    this.sent.push({ kind, payload: payload.toString("utf8") })
  }
  recv = (): Promise<TunnelMessage | null> => settle(this.incoming)
  finish = async (): Promise<void> => undefined
}

/// A QUIC connection; closing it ends `ends` (its stream), like the real one.
const connection = (
  alpn: string,
  remoteId = "e".repeat(64),
  stream: Promise<TunnelMessageStream> = Promise.resolve(new FakeStream()),
  ends?: FakeStream
): TunnelConnection & { close: ReturnType<typeof vi.fn> } =>
  ({
    remoteId: () => remoteId,
    alpn: () => alpn,
    acceptMessageStream: () => stream,
    close: vi.fn(() => ends?.incoming.push({ error: new Error("connection closed") }))
  }) as unknown as TunnelConnection & { close: ReturnType<typeof vi.fn> }

class FakeEndpoint {
  incoming = new Pending<Outcome<TunnelConnection | null>>()
  addrs = new Pending<Outcome<TunnelAddr>>()
  closed = false
  endpointId = (): string => "a".repeat(64)
  accept = (): Promise<TunnelConnection | null> => settle(this.incoming)
  nextAddr = (): Promise<TunnelAddr> => settle(this.addrs)
  async close(): Promise<void> {
    this.closed = true
    this.incoming.push({ value: null })
    this.addrs.push({ error: new Error("closed") })
  }
}

/// Resolves with the socket's close code.
const closeCode = (socket: { onclose: ((code: number) => void) | null }): Promise<number> =>
  new Promise((resolve) => {
    // oxlint-disable-next-line unicorn/prefer-add-event-listener -- CloudSocket is a callback-property interface with no addEventListener
    socket.onclose = resolve
  })

describe("tunnelSocket", () => {
  it("carries text and binary messages in order and closes with the stream", async () => {
    const stream = new FakeStream()
    const conn = connection(TUNNEL_ALPN_CHANNELS)
    const socket = tunnelSocket(stream, conn)
    const received: (string | Uint8Array)[] = []
    // oxlint-disable-next-line unicorn/prefer-add-event-listener -- CloudSocket is a callback-property interface with no addEventListener
    socket.onmessage = (data) => received.push(data)
    const closed = closeCode(socket)

    socket.send('{"t":"welcome"}')
    socket.send(new Uint8Array([1, 2, 3]))
    stream.incoming.push({ value: { kind: 0, payload: Buffer.from('{"t":"hello"}') } })
    stream.incoming.push({ value: { kind: 1, payload: Buffer.from([9, 8]) } })
    stream.incoming.push({ value: null })
    // The stream only ends after both messages were delivered in order.
    expect(await closed).toBe(1000)

    expect(stream.sent).toEqual([
      { kind: 0, payload: '{"t":"welcome"}' },
      { kind: 1, payload: "\u0001\u0002\u0003" }
    ])
    expect(received).toEqual(['{"t":"hello"}', new Uint8Array([9, 8])])
    expect(() => socket.send("late")).toThrow(/closed/)
  })

  it("reports a failed stream as an abnormal close", async () => {
    const stream = new FakeStream()
    const socket = tunnelSocket(stream, connection(TUNNEL_ALPN_CHANNELS))
    const closed = closeCode(socket)
    stream.incoming.push({ error: new Error("reset") })
    expect(await closed).toBe(1006)
  })

  it("treats a failed send as an abnormal close", async () => {
    const stream = new FakeStream()
    stream.sendError = new Error("stream reset")
    const conn = connection(TUNNEL_ALPN_CHANNELS, undefined, undefined, stream)
    const socket = tunnelSocket(stream, conn)
    const closed = closeCode(socket)
    socket.send("hello")
    expect(await closed).toBe(1006)
    expect(conn.close).toHaveBeenCalledWith(1006, "send failed")
  })

  it("closes the QUIC connection once and reports the requested code", async () => {
    const stream = new FakeStream()
    const conn = connection(TUNNEL_ALPN_CHANNELS, undefined, undefined, stream)
    const socket = tunnelSocket(stream, conn)
    const closed = closeCode(socket)
    socket.close(4202, "device is not paired")
    socket.terminate!()
    expect(conn.close).toHaveBeenCalledExactlyOnceWith(4202, "device is not paired")
    expect(() => socket.send("late")).toThrow(/closed/)
    expect(await closed).toBe(4202)
  })

  it("ends the connection, not the server, when a message handler throws", async () => {
    const stream = new FakeStream()
    const conn = connection(TUNNEL_ALPN_CHANNELS, undefined, undefined, stream)
    const socket = tunnelSocket(stream, conn)
    const received: (string | Uint8Array)[] = []
    // oxlint-disable-next-line unicorn/prefer-add-event-listener -- CloudSocket is a callback-property interface with no addEventListener
    socket.onmessage = (data) => {
      received.push(data)
      throw new Error("tunnel stream is closed")
    }
    const closed = closeCode(socket)
    // Both arrive before the loop runs: the second is already queued when
    // the first handler's failure closes the socket.
    stream.incoming.push({ value: { kind: 0, payload: Buffer.from('{"t":"ping"}') } })
    stream.incoming.push({ value: { kind: 0, payload: Buffer.from('{"t":"ping"}') } })
    expect(await closed).toBe(1011)
    expect(conn.close).toHaveBeenCalledExactlyOnceWith(1011, "message handler failed")
    // A closed socket delivers nothing further.
    expect(received).toEqual(['{"t":"ping"}'])
  })
})

describe("admitTunnelHello", () => {
  const device = { deviceId: "app-1", publicKey: "x25519-key" }
  const voucher: CloudVouchedDevice = { ...device, endpointId: "e1" }
  const setup = (vouched: CloudVouchedDevice[] = []) => {
    const keys = makePeerKeyPinStore({})
    const endpoints = makePeerKeyPinStore({})
    const admit = admitTunnelHello(
      { keys, endpoints },
      () => new Map(vouched.map((entry) => [entry.deviceId, entry]))
    )
    return { keys, endpoints, admit }
  }

  it("admits a vouched first contact and pins both identities", () => {
    const { keys, endpoints, admit } = setup([voucher])
    expect(admit(device, { endpointId: "e1" })).toBe(true)
    expect(keys.get("app-1")).toBe("x25519-key")
    expect(endpoints.get("app-1")).toBe("e1")
  })

  it("keeps admitting a pinned device after the hub stops vouching", () => {
    const { admit } = setup([voucher])
    expect(admit(device, { endpointId: "e1" })).toBe(true)
    const later = admitTunnelHello(
      {
        keys: makePeerKeyPinStore({ initial: { "app-1": "x25519-key" } }),
        endpoints: makePeerKeyPinStore({ initial: { "app-1": "e1" } })
      },
      () => new Map()
    )
    expect(later(device, { endpointId: "e1" })).toBe(true)
  })

  it("refuses unknown devices, missing endpoints and any identity mismatch", () => {
    expect(setup().admit(device, { endpointId: "e1" })).toBe(false)
    expect(setup([voucher]).admit(device, {})).toBe(false)
    expect(setup([voucher]).admit(device, { endpointId: "other" })).toBe(false)
    expect(setup([{ ...voucher, publicKey: "other" }]).admit(device, { endpointId: "e1" })).toBe(
      false
    )

    // Pins win over the hub: a changed key or endpoint is refused even if vouched.
    const pinned = setup([voucher])
    pinned.admit(device, { endpointId: "e1" })
    expect(pinned.admit({ ...device, publicKey: "swapped" }, { endpointId: "e1" })).toBe(false)
    expect(pinned.admit(device, { endpointId: "e2" })).toBe(false)
  })
})

describe("MachineTunnel", () => {
  const relays = [{ url: "https://relay-a.test", quicPort: 7842 }]
  const setup = () => {
    const endpoints: FakeEndpoint[] = []
    const bindOptions: EndpointOptions[] = []
    const accepted = new Pending<{ endpointId?: string }>()
    const media: TunnelConnection[] = []
    const addrs = new Pending<unknown>()
    const logs: string[] = []
    const tunnel = new MachineTunnel({
      bind: async (options) => {
        bindOptions.push(options)
        const endpoint = new FakeEndpoint()
        endpoints.push(endpoint)
        return endpoint as unknown as TunnelEndpoint
      },
      secretKeyHex: "11".repeat(32),
      host: { accept: (_socket, peer) => accepted.push(peer ?? {}) },
      onAddr: (addr) => addrs.push(addr),
      onMedia: (conn) => media.push(conn),
      log: (line) => logs.push(line)
    })
    return { tunnel, endpoints, bindOptions, accepted, media, addrs, logs }
  }

  it("binds once per relay map and rebinds when it changes", async () => {
    const { tunnel, endpoints, bindOptions } = setup()
    await tunnel.configure({ relays: [], enabled: false })
    expect(endpoints).toHaveLength(0)

    await tunnel.configure({ relays, enabled: true })
    await tunnel.configure({ relays, enabled: true })
    expect(endpoints).toHaveLength(1)
    expect(bindOptions[0]).toEqual({
      secretKeyHex: "11".repeat(32),
      relays: [{ url: "https://relay-a.test", quicPort: 7842 }],
      trustAnchorsPem: [],
      bindAddrs: [],
      pathPolicy: "auto",
      alpns: [TUNNEL_ALPN_CHANNELS, TUNNEL_ALPN_MEDIA]
    })
    expect(tunnel.endpoint).toBe(endpoints[0])

    await tunnel.configure({ relays: [{ url: "https://relay-b.test" }], enabled: true })
    expect(endpoints[0]!.closed).toBe(true)
    expect(bindOptions[1]!.relays).toEqual([{ url: "https://relay-b.test" }])

    await tunnel.configure({ relays, enabled: false })
    expect(endpoints[1]!.closed).toBe(true)
    expect(tunnel.endpoint).toBeUndefined()
  })

  it("publishes every address change to the hub", async () => {
    const { tunnel, endpoints, addrs } = setup()
    await tunnel.configure({ relays, enabled: true })
    const endpoint = endpoints[0]!
    endpoint.addrs.push({ value: { endpointId: "a".repeat(64), relayUrl: null, directAddrs: [] } })
    endpoint.addrs.push({
      value: {
        endpointId: "a".repeat(64),
        relayUrl: "https://relay-a.test/",
        directAddrs: ["192.168.1.4:41641"]
      }
    })
    expect(await addrs.next()).toEqual({ endpointId: "a".repeat(64), directAddrs: [] })
    expect(await addrs.next()).toEqual({
      endpointId: "a".repeat(64),
      relayUrl: "https://relay-a.test/",
      directAddrs: ["192.168.1.4:41641"]
    })
  })

  it("routes channel connections to the host with the verified endpoint id", async () => {
    const { tunnel, endpoints, accepted, media, logs } = setup()
    await tunnel.configure({ relays, enabled: true })
    const endpoint = endpoints[0]!
    const unsupported = connection("other/1")
    const mediaConnection = connection(TUNNEL_ALPN_MEDIA)
    // The accept loop handles connections in order; the last one reaching
    // the host proves every earlier one was dispatched.
    endpoint.incoming.push({ error: new Error("bad handshake") })
    endpoint.incoming.push({ value: mediaConnection })
    endpoint.incoming.push({ value: unsupported })
    endpoint.incoming.push({
      value: connection(TUNNEL_ALPN_CHANNELS, "g", Promise.reject(new Error("gone")))
    })
    endpoint.incoming.push({ value: connection(TUNNEL_ALPN_CHANNELS, "f".repeat(64)) })

    expect(await accepted.next()).toEqual({ endpointId: "f".repeat(64) })
    expect(media).toEqual([mediaConnection])
    expect(unsupported.close).toHaveBeenCalledWith(1, "unsupported service")
    expect(logs).toContain("Tunnel: handshake failed: Error: bad handshake")
  })

  it("ignores a replaced endpoint's late addresses and connections", async () => {
    const endpoints: FakeEndpoint[] = []
    const addrs = new Pending<unknown>()
    const accepted = new Pending<{ endpointId?: string }>()
    const tunnel = new MachineTunnel({
      bind: async () => {
        const endpoint = new FakeEndpoint()
        // Replaced endpoints' closes don't end their loops, so late results
        // still arrive after they were replaced.
        if (endpoints.length < 2) endpoint.close = async () => undefined
        endpoints.push(endpoint)
        return endpoint as unknown as TunnelEndpoint
      },
      secretKeyHex: "33".repeat(32),
      host: { accept: (_socket, peer) => accepted.push(peer ?? {}) },
      onAddr: (addr) => addrs.push(addr)
    })
    await tunnel.configure({ relays, enabled: true })
    await tunnel.configure({ relays: [], enabled: true })
    await tunnel.configure({ relays: [{ url: "https://relay-c.test" }], enabled: true })
    const [staleA, staleB, current] = [endpoints[0]!, endpoints[1]!, endpoints[2]!]
    // Queued first, so the stale loops run (and bail) before the current ones.
    staleA.addrs.push({ value: { endpointId: "stale", directAddrs: [] } })
    staleA.incoming.push({ error: new Error("handshake after replacement") })
    staleB.incoming.push({ value: connection(TUNNEL_ALPN_CHANNELS, "stale") })
    current.addrs.push({ value: { endpointId: "current", directAddrs: [] } })
    current.incoming.push({ value: connection(TUNNEL_ALPN_CHANNELS, "current") })
    expect(await addrs.next()).toEqual({ endpointId: "current", directAddrs: [] })
    expect(await accepted.next()).toEqual({ endpointId: "current" })
  })

  it("discards an endpoint whose bind lost a race with stop", async () => {
    let release!: () => void
    let bindStarted!: () => void
    const binding = new Promise<void>((resolve) => {
      bindStarted = resolve
    })
    const endpoint = new FakeEndpoint()
    const tunnel = new MachineTunnel({
      bind: () =>
        new Promise((resolve) => {
          release = () => resolve(endpoint as unknown as TunnelEndpoint)
          bindStarted()
        }),
      secretKeyHex: "22".repeat(32),
      host: { accept: vi.fn() },
      onAddr: vi.fn()
    })
    const configuring = tunnel.configure({ relays, enabled: true })
    await binding
    await tunnel.stop()
    release()
    await configuring
    expect(endpoint.closed).toBe(true)
    expect(tunnel.endpoint).toBeUndefined()
  })
})
