import type { CloudRelayInfo, CloudTunnelInfo, CloudVouchedDevice } from "@codevisor/api"
import type {
  EndpointOptions,
  PathPolicy,
  TunnelConnection,
  TunnelEndpoint,
  TunnelMessageStream
} from "@codevisor/net"

import type { DirectChannelHost, PipePeer } from "./direct-channel-host.js"
import type { TunnelConfig } from "./hub-frames.js"
import type { CloudSocket } from "./machine-socket.js"
import type { PeerKeyPinStore } from "./peer-pins.js"

export const TUNNEL_ALPN_CHANNELS = "codevisor/channels/1"
export const TUNNEL_ALPN_MEDIA = "codevisor/media/1"

const TEXT = 0
const BINARY = 1

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
        socket.close(1011, "message handler failed")
      }
    }
    ended = true
    try {
      socket.onclose?.(requestedClose ?? endCode)
    } catch {}
  })()
  return socket
}

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

const bindingKey = (relays: readonly CloudRelayInfo[], pathPolicy: PathPolicy): string =>
  JSON.stringify([pathPolicy, relays.map((relay) => [relay.url, relay.quicPort ?? null])])

export class MachineTunnel {
  #endpoint: TunnelEndpoint | undefined
  #bindingKey: string | undefined
  #generation = 0
  #config: TunnelConfig | undefined
  #pathPolicy: PathPolicy

  constructor(private readonly options: MachineTunnelOptions) {
    this.#pathPolicy = options.pathPolicy ?? "auto"
  }

  get pathPolicy(): PathPolicy {
    return this.#pathPolicy
  }

  async setPathPolicy(pathPolicy: PathPolicy): Promise<void> {
    if (pathPolicy === this.#pathPolicy) return
    this.#pathPolicy = pathPolicy
    if (this.#config !== undefined) await this.configure(this.#config)
  }

  async configure(config: TunnelConfig): Promise<void> {
    if (!config.enabled) {
      await this.stop()
      return
    }
    this.#config = config
    const pathPolicy = this.#pathPolicy
    const key = bindingKey(config.relays, pathPolicy)
    if (this.#endpoint !== undefined && this.#bindingKey === key) return
    const stopping = this.#closeEndpoint()
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
      pathPolicy,
      alpns: [TUNNEL_ALPN_CHANNELS, TUNNEL_ALPN_MEDIA]
    })
    if (generation !== this.#generation) {
      await endpoint.close()
      return
    }
    this.#endpoint = endpoint
    this.#bindingKey = key
    this.options.log?.(`Tunnel: listening as ${endpoint.endpointId()} (${pathPolicy})`)
    void this.#publishAddresses(endpoint)
    void this.#acceptLoop(endpoint)
  }

  stop(): Promise<void> {
    this.#config = undefined
    return this.#closeEndpoint()
  }

  async #closeEndpoint(): Promise<void> {
    this.#generation += 1
    const endpoint = this.#endpoint
    this.#endpoint = undefined
    this.#bindingKey = undefined
    await endpoint?.close()
  }

  async #publishAddresses(endpoint: TunnelEndpoint): Promise<void> {
    for (;;) {
      let addr
      try {
        addr = await endpoint.nextAddr()
      } catch {
        return
      }
      if (this.#endpoint !== endpoint) return
      this.options.onAddr({
        endpointId: addr.endpointId,
        ...(addr.relayUrl == null ? {} : { relayUrl: addr.relayUrl }),
        directAddrs: addr.directAddrs
      })
    }
  }

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
      return
    }
    this.options.host.accept(tunnelSocket(stream, connection), {
      endpointId: connection.remoteId()
    })
  }
}
