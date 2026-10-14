import {
  CLOUD_PROTOCOL_VERSION,
  decodeAppToHub,
  decodeRelayEnvelopes,
  encodeCloudFrame,
  encodeRelayEnvelopes,
  parseAppRelayHeader,
  type RelayFrameHeader
} from "@codevisor/api"

import { ChannelReceiver } from "./channel-receiver.js"
import type { ChannelHandler } from "./incoming-channel.js"
import type { CancelTimeout, CloudSocket } from "./machine-socket.js"
import type { PeerKeyPinStore } from "./peer-pins.js"

export const DIRECT_CLOSE_INVALID = 4000
export const DIRECT_CLOSE_HELLO_TIMEOUT = 4002
export const DIRECT_CLOSE_UNSUPPORTED_PROTOCOL = 4200
export const DIRECT_CLOSE_UNPINNED = 4202

export interface DirectChannelHostOptions {
  deviceId: string
  secretKey: string
  channelHandlers: Record<string, ChannelHandler>
  peerKeyPins: PeerKeyPinStore
  compressPayload?: (bytes: Uint8Array) => Uint8Array | undefined
  decompressPayload?: (bytes: Uint8Array) => Uint8Array
  scheduleTimeout?: (callback: () => void, delayMs: number) => CancelTimeout
  log?: (line: string) => void
  admitHello?: (device: { deviceId: string; publicKey: string }, peer: PipePeer) => boolean
}

export interface PipePeer {
  endpointId?: string
}

export class DirectChannelHost {
  #accepted = 0

  constructor(private readonly options: DirectChannelHostOptions) {}

  accept(socket: CloudSocket, peer: PipePeer = {}): void {
    this.#accepted += 1
    const connectionId = `direct-${this.#accepted}`
    const options = this.options
    let hello: { deviceId: string; publicKey: string } | undefined
    const receiver = new ChannelReceiver({
      secretKey: options.secretKey,
      channelHandlers: options.channelHandlers,
      peerKeyPins: options.peerKeyPins,
      ...(options.compressPayload === undefined
        ? {}
        : { compressPayload: options.compressPayload }),
      ...(options.decompressPayload === undefined
        ? {}
        : { decompressPayload: options.decompressPayload }),
      sendEnvelope: (_peerId, frame, payload) => this.#sendEnvelope(socket, frame, payload),
      ready: () => true
    })
    const scheduleTimeout =
      options.scheduleTimeout ??
      ((callback: () => void, delayMs: number): CancelTimeout => {
        const timeout = setTimeout(callback, delayMs)
        return () => clearTimeout(timeout)
      })
    let cancelHelloTimeout: CancelTimeout | undefined = scheduleTimeout(() => {
      cancelHelloTimeout = undefined
      socket.close(DIRECT_CLOSE_HELLO_TIMEOUT, "hello timeout")
    }, 10_000)

    // oxlint-disable-next-line unicorn/prefer-add-event-listener
    socket.onmessage = (data) => {
      if (typeof data === "string") {
        this.#onControl(socket, data, hello, peer, (accepted) => {
          hello = accepted
          cancelHelloTimeout?.()
          cancelHelloTimeout = undefined
          this.#send(
            socket,
            encodeCloudFrame({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION, connectionId })
          )
        })
        return
      }
      if (hello === undefined) {
        socket.close(DIRECT_CLOSE_INVALID, "hello required before relaying")
        return
      }
      let envelopes
      try {
        envelopes = decodeRelayEnvelopes(data)
      } catch {
        socket.close(DIRECT_CLOSE_INVALID, "malformed relay message")
        return
      }
      for (const envelope of envelopes) {
        const header = parseAppRelayHeader(envelope.header)
        if (header === undefined || header.machineId !== options.deviceId) continue
        receiver.handleRelay(
          connectionId,
          header.frame,
          envelope.payload,
          hello.publicKey,
          hello.deviceId
        )
      }
    }
    // oxlint-disable-next-line unicorn/prefer-add-event-listener
    socket.onclose = () => {
      cancelHelloTimeout?.()
      cancelHelloTimeout = undefined
      receiver.dropAll("peer-gone")
    }
  }

  #onControl(
    socket: CloudSocket,
    data: string,
    hello: { deviceId: string; publicKey: string } | undefined,
    peer: PipePeer,
    onHello: (accepted: { deviceId: string; publicKey: string }) => void
  ): void {
    let frame
    try {
      frame = decodeAppToHub(data)
    } catch {
      socket.close(DIRECT_CLOSE_INVALID, "malformed control frame")
      return
    }
    if (frame.t === "ping") {
      this.#send(socket, encodeCloudFrame({ t: "pong" }))
      return
    }
    if (hello !== undefined) return
    if (frame.protocol !== CLOUD_PROTOCOL_VERSION) {
      socket.close(DIRECT_CLOSE_UNSUPPORTED_PROTOCOL, "unsupported protocol")
      return
    }
    const device = { deviceId: frame.device.deviceId, publicKey: frame.device.publicKey }
    const admitted =
      this.options.admitHello?.(device, peer) ??
      this.options.peerKeyPins.get(device.deviceId) === device.publicKey
    if (frame.device.kind !== "app" || !admitted) {
      this.options.log?.(`Direct: refused connection from unpinned device ${frame.device.deviceId}`)
      socket.close(DIRECT_CLOSE_UNPINNED, "device is not paired with this machine")
      return
    }
    onHello({ deviceId: frame.device.deviceId, publicKey: frame.device.publicKey })
  }

  #sendEnvelope(
    socket: CloudSocket,
    frame: RelayFrameHeader,
    payload: Uint8Array = new Uint8Array(0)
  ): void {
    this.#send(
      socket,
      encodeRelayEnvelopes([{ header: { machineId: this.options.deviceId, frame }, payload }])
    )
  }

  #send(socket: CloudSocket, data: string | Uint8Array): void {
    try {
      socket.send(data)
    } catch {}
  }
}
