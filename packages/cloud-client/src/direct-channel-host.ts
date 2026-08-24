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

/// The direct pipe, machine side: accepts sealed-channel connections straight
/// from apps on the same network — same wire format as the hub relay (JSON
/// text hello/welcome/ping, binary envelope batches), same ChannelReceiver,
/// no hub in the middle. Unlike the relay there is no account gate in front,
/// so identity is mandatory: a hello from a device whose key is not ALREADY
/// pinned (established through prior relay use — TOFU happens there, never
/// here) is refused before any channel can open. The E2E channel crypto then
/// authenticates every frame, so the pipe needs no TLS of its own.
///
/// Channels die with their connection; apps re-open from durable cursors on
/// whatever pipe is available next (LAN reconnects are instant, and the
/// relay is always the fallback). No resume machinery on this pipe.

export const DIRECT_CHANNEL_PATH = "/v1/direct"

/// Close codes, mirroring the hub's conventions (42xx fatal).
export const DIRECT_CLOSE_INVALID = 4000
export const DIRECT_CLOSE_HELLO_TIMEOUT = 4002
export const DIRECT_CLOSE_UNSUPPORTED_PROTOCOL = 4200
/// The presented device identity has no matching pin: this pipe never
/// trusts on first use. Fatal — pair through the relay first.
export const DIRECT_CLOSE_UNPINNED = 4202

export interface DirectChannelHostOptions {
  /// This machine's cloud device id — the address apps put in relay headers.
  deviceId: string
  /// This machine's static X25519 secret key (base64url).
  secretKey: string
  channelHandlers: Record<string, ChannelHandler>
  /// The SAME pin store the relay connection uses; get-only here.
  peerKeyPins: PeerKeyPinStore
  compressPayload?: (bytes: Uint8Array) => Uint8Array | undefined
  decompressPayload?: (bytes: Uint8Array) => Uint8Array
  helloTimeoutMs?: number
  scheduleTimeout?: (callback: () => void, delayMs: number) => CancelTimeout
  log?: (line: string) => void
}

export class DirectChannelHost {
  #accepted = 0

  constructor(private readonly options: DirectChannelHostOptions) {}

  /// Adopts one server-accepted WebSocket as a direct channel pipe.
  accept(socket: CloudSocket): void {
    this.#accepted += 1
    const connectionId = `direct-${this.#accepted}`
    const options = this.options
    let hello: { deviceId: string; publicKey: string } | undefined
    const receiver = new ChannelReceiver({
      secretKey: options.secretKey,
      channelHandlers: options.channelHandlers,
      // The hello gate below guarantees the pinned identity; the receiver's
      // own pin check then re-verifies it per open (defense in depth).
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
    }, options.helloTimeoutMs ?? 10_000)

    socket.onmessage = (data) => {
      if (typeof data === "string") {
        this.#onControl(socket, data, hello, (accepted) => {
          hello = accepted
          cancelHelloTimeout?.()
          cancelHelloTimeout = undefined
          socket.send(
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
        // Ignore malformed or misaddressed envelopes rather than tearing the
        // pipe down; the channel-level seq contract catches real corruption.
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
      socket.send(encodeCloudFrame({ t: "pong" }))
      return
    }
    if (hello !== undefined) return // duplicate hello — ignore
    if (frame.protocol !== CLOUD_PROTOCOL_VERSION) {
      socket.close(DIRECT_CLOSE_UNSUPPORTED_PROTOCOL, "unsupported protocol")
      return
    }
    // No TOFU here: only identities already pinned through the relay may
    // open a direct pipe (anyone on the LAN can reach this listener).
    const pinned = this.options.peerKeyPins.get(frame.device.deviceId)
    if (frame.device.kind !== "app" || pinned === undefined || pinned !== frame.device.publicKey) {
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
    try {
      socket.send(
        encodeRelayEnvelopes([{ header: { machineId: this.options.deviceId, frame }, payload }])
      )
    } catch {
      // The socket's close event tears the connection's channels down.
    }
  }
}
