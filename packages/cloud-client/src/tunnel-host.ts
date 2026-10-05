import type { CloudRelayInfo, CloudTunnelInfo, CloudVouchedDevice } from "@codevisor/api"
import type {
  EndpointOptions,
  PathPolicy,
  TunnelConnection,
  TunnelEndpoint,
  TunnelMessageStream
} from "@codevisor/net"

import type { DirectChannelHost, PipePeer } from "./direct-channel-host.js"
import type { CloudSocket } from "./machine-socket.js"
import type { PeerKeyPinStore } from "./peer-pins.js"

/// The machine side of the tunnel (docs/plans/codevisor-tunnel.md): one iroh
/// endpoint that apps dial by key, directly or through our relays. Each
/// `codevisor/channels/1` connection carries the existing sealed channel
/// protocol on one message stream, handed to the same DirectChannelHost the
/// LAN pipe uses — only the identity gate differs (admitTunnelHello).

export const TUNNEL_ALPN_CHANNELS = "codevisor/channels/1"
export const TUNNEL_ALPN_MEDIA = "codevisor/media/1"

const TEXT = 0
const BINARY = 1

/// Adapts one tunnel message stream to the CloudSocket surface the channel
/// hosts speak. Sends are chained so messages keep their order. Closing (or a
/// failed send) closes the QUIC connection, which ends the stream; the read
/// loop is the one place that reports `onclose`, so it fires exactly once.
/// The read loop runs detached, so nothing thrown by the owner's handlers may
/// escape it: that would be an unhandled rejection, and it exits the server.
export const tunnelSocket = (
  stream: TunnelMessageStream,
  connection: Pick<TunnelConnection, "close">
): CloudSocket => {
  let requestedClose: number | undefined
  let ended = false
  let sending: Promise<void> = Promise.resolve()
  const socket: CloudSocket = {
    onopen: null,
    onmessage: null,
    onclose: null,
    send(data) {
      if (ended || requestedClose !== undefined) throw new Error("tunnel stream is closed")
      const payload =
        typeof data === "string"
          ? Buffer.from(data, "utf8")
          : Buffer.from(data.buffer, data.byteOffset, data.byteLength)
      const kind = typeof data === "string" ? TEXT : BINARY
      sending = sending
        .then(() => stream.send(kind, payload))
        .catch(() => socket.close(1006, "send failed"))
    },
    close(code = 1000, reason = "") {
      if (requestedClose !== undefined) return
      requestedClose = code
      connection.close(code, reason)
    },
    terminate() {
      socket.close(1006, "terminated")
    }
  }
  void (async () => {
    let endCode = 1000
    for (;;) {
      let message
      try {
        message = await stream.recv()
      } catch {
        endCode = 1006
        break
      }
      if (message === null) break
      // A socket its owner closed delivers nothing further (as a browser
      // WebSocket drops messages once it leaves OPEN); keep draining so the
      // stream's end still reports onclose.
      if (requestedClose !== undefined) continue
      try {
        socket.onmessage?.(
          message.kind === TEXT
            ? message.payload.toString("utf8")
            : new Uint8Array(
                message.payload.buffer,
                message.payload.byteOffset,
                message.payload.byteLength
              )
        )
      } catch {
        // A handler that fails ends this connection, not the server.
        socket.close(1011, "message handler failed")
      }
    }
    ended = true
    try {
      socket.onclose?.(requestedClose ?? endCode)
    } catch {
      // Same detached loop: a failing close handler must not exit the server.
    }
  })()
  return socket
}

/// The tunnel's identity gate. The QUIC handshake already proved which
/// endpoint key is on the other end; the hello names a device and its X25519
/// key. Admit when both match what this machine pinned, or — first contact —
/// what the hub vouches for (then pin both). Pins are never overwritten: a
/// device that later presents another key or endpoint is refused, so a
/// misbehaving hub can't redirect an established pairing.
export const admitTunnelHello =
  (
    pins: { keys: PeerKeyPinStore; endpoints: PeerKeyPinStore },
    vouched: () => ReadonlyMap<string, CloudVouchedDevice>
  ) =>
  (device: { deviceId: string; publicKey: string }, peer: PipePeer): boolean => {
    const endpointId = peer.endpointId
    if (endpointId === undefined) return false
    const pinnedKey = pins.keys.get(device.deviceId)
    const pinnedEndpoint = pins.endpoints.get(device.deviceId)
    if (pinnedKey !== undefined && pinnedKey !== device.publicKey) return false
    if (pinnedEndpoint !== undefined && pinnedEndpoint !== endpointId) return false
    if (pinnedKey === undefined || pinnedEndpoint === undefined) {
      const voucher = vouched().get(device.deviceId)
      if (voucher?.publicKey !== device.publicKey || voucher.endpointId !== endpointId) return false
      pins.keys.set(device.deviceId, device.publicKey)
      pins.endpoints.set(device.deviceId, endpointId)
    }
    return true
  }

/// Serves one accepted media connection (Phase 4: screen-sharing UDP flows).
export type MediaConnectionHandler = (connection: TunnelConnection) => void

export interface MachineTunnelOptions {
  bind: (options: EndpointOptions) => Promise<TunnelEndpoint>
  secretKeyHex: string
  host: Pick<DirectChannelHost, "accept">
  onAddr: (tunnel: CloudTunnelInfo) => void
  onMedia?: MediaConnectionHandler
  trustAnchorsPem?: string[]
  bindAddrs?: string[]
  pathPolicy?: PathPolicy
  log?: (line: string) => void
}

const relayKey = (relays: readonly CloudRelayInfo[]): string =>
  JSON.stringify(relays.map((relay) => [relay.url, relay.quicPort ?? null]))

/// Owns the endpoint's lifecycle: bound while the hub has the tunnel enabled,
/// rebound when the relay map changes, closed on stop.
export class MachineTunnel {
  #endpoint: TunnelEndpoint | undefined
  #relays: string | undefined
  #generation = 0

  constructor(private readonly options: MachineTunnelOptions) {}

  get endpoint(): TunnelEndpoint | undefined {
    return this.#endpoint
  }

  /// Applies a welcome's tunnel config. Safe to call repeatedly.
  async configure(config: { relays: readonly CloudRelayInfo[]; enabled: boolean }): Promise<void> {
    if (!config.enabled) {
      await this.stop()
      return
    }
    const key = relayKey(config.relays)
    if (this.#endpoint !== undefined && this.#relays === key) return
    // stop claims ownership synchronously; capture it before awaiting teardown.
    const stopping = this.stop()
    const generation = this.#generation
    await stopping
    if (generation !== this.#generation) return
    const endpoint = await this.options.bind({
      secretKeyHex: this.options.secretKeyHex,
      relays: config.relays.map((relay) => ({
        url: relay.url,
        ...(relay.quicPort === undefined ? {} : { quicPort: relay.quicPort })
      })),
      trustAnchorsPem: this.options.trustAnchorsPem ?? [],
      bindAddrs: this.options.bindAddrs ?? [],
      pathPolicy: this.options.pathPolicy ?? "auto",
      alpns: [TUNNEL_ALPN_CHANNELS, TUNNEL_ALPN_MEDIA]
    })
    if (generation !== this.#generation) {
      // stop()/configure() raced this bind; the newer call owns the tunnel.
      await endpoint.close()
      return
    }
    this.#endpoint = endpoint
    this.#relays = key
    this.options.log?.(`Tunnel: listening as ${endpoint.endpointId()}`)
    void this.#publishAddresses(endpoint)
    void this.#acceptLoop(endpoint)
  }

  async stop(): Promise<void> {
    this.#generation += 1
    const endpoint = this.#endpoint
    this.#endpoint = undefined
    this.#relays = undefined
    await endpoint?.close()
  }

  async #publishAddresses(endpoint: TunnelEndpoint): Promise<void> {
    for (;;) {
      let addr
      try {
        addr = await endpoint.nextAddr()
      } catch {
        return // endpoint closed
      }
      if (this.#endpoint !== endpoint) return
      this.options.onAddr({
        endpointId: addr.endpointId,
        ...(addr.relayUrl == null ? {} : { relayUrl: addr.relayUrl }),
        directAddrs: addr.directAddrs
      })
    }
  }

  /// `accept` hands over connections in the order their handshakes finish
  /// (codevisor-net runs them concurrently), so a dialer that stalls
  /// mid-handshake never holds up the ones behind it.
  async #acceptLoop(endpoint: TunnelEndpoint): Promise<void> {
    for (;;) {
      let connection: TunnelConnection | null
      try {
        connection = await endpoint.accept()
      } catch (error) {
        if (this.#endpoint !== endpoint) return
        this.options.log?.(`Tunnel: handshake failed: ${String(error)}`)
        continue
      }
      if (connection === null || this.#endpoint !== endpoint) return
      void this.#serve(connection)
    }
  }

  async #serve(connection: TunnelConnection): Promise<void> {
    if (connection.alpn() === TUNNEL_ALPN_MEDIA && this.options.onMedia !== undefined) {
      this.options.onMedia(connection)
      return
    }
    if (connection.alpn() !== TUNNEL_ALPN_CHANNELS) {
      connection.close(1, "unsupported service")
      return
    }
    let stream
    try {
      stream = await connection.acceptMessageStream()
    } catch {
      return // the peer went away before opening its stream
    }
    this.options.host.accept(tunnelSocket(stream, connection), {
      endpointId: connection.remoteId()
    })
  }
}
