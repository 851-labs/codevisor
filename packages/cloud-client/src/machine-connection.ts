import {
  CLOUD_PROTOCOL_VERSION,
  encodeCloudFrame,
  MACHINE_PEERS_FEATURE,
  parseHubToAppRelayHeader,
  parseHubToMachineRelayHeader,
  type CloudMachinePresence,
  type CloudTunnelInfo,
  type MachineToHub,
  type RelayFrameHeader,
  type WireRelayEnvelope
} from "@codevisor/api"

import type { OutgoingChannel } from "./channel-opener.js"
import { ChannelReceiver } from "./channel-receiver.js"
import {
  decodeRelayBatch,
  tunnelConfigOf,
  type HubFrame,
  type WelcomeResume
} from "./hub-frames.js"
import { releaseChannelField, type MachineConnectionOptions } from "./machine-connection-options.js"
import { MachinePeers } from "./machine-peers.js"
import {
  decodeHubFrame,
  RelayOutbox,
  reconnectDelayMs,
  REVOKED_RECHECK_MS,
  type CancelTimeout,
  type CloudSocket,
  type MachineConnectionState,
  isCredentialRejection,
  type MachineDisconnectReason
} from "./machine-socket.js"

const RESUME_RETAIN_CAP_BYTES = 256 * 1024

export type { MachineConnectionOptions } from "./machine-connection-options.js"

export class CloudMachineConnection {
  #socket: CloudSocket | undefined
  #outbox: RelayOutbox | undefined
  #state: MachineConnectionState = "stopped"
  #attempt = 0
  #stopped = true
  #reconnectGeneration = 0
  #cancelWelcomeTimeout: CancelTimeout | undefined
  #cancelHeartbeat: CancelTimeout | undefined
  #cancelPongTimeout: CancelTimeout | undefined
  readonly #receiver: ChannelReceiver
  readonly #peers: MachinePeers
  #resumeToken: string | undefined
  #connectionId: string | undefined
  #retained: { header: unknown; payload: Uint8Array }[] = []
  #retainedBytes = 0

  constructor(private readonly options: MachineConnectionOptions) {
    this.#receiver = new ChannelReceiver({
      secretKey: options.credentials.secretKey,
      channelHandlers: options.channelHandlers,
      ...(options.peerKeyPins === undefined ? {} : { peerKeyPins: options.peerKeyPins }),
      ...(options.onPeerKeyMismatch === undefined
        ? {}
        : { onPeerKeyMismatch: options.onPeerKeyMismatch }),
      ...(options.compressPayload === undefined
        ? {}
        : { compressPayload: options.compressPayload }),
      ...(options.decompressPayload === undefined
        ? {}
        : { decompressPayload: options.decompressPayload }),
      sendEnvelope: (peerId, frame, payload) => this.#sendEnvelope({ peerId, frame }, payload),
      ready: () => this.#outbox !== undefined || this.#resumable()
    })
    this.#peers = new MachinePeers({
      selfDeviceId: options.credentials.deviceId,
      secretKey: options.credentials.secretKey,
      ...(options.peerKeyPins === undefined ? {} : { peerKeyPins: options.peerKeyPins }),
      ...(options.onPeerKeyMismatch === undefined
        ? {}
        : { onPeerKeyMismatch: options.onPeerKeyMismatch }),
      sendEnvelope: (machineId, frame, payload) => this.#sendEnvelope({ machineId, frame }, payload)
    })
  }

  machines(): ReadonlyArray<CloudMachinePresence> | undefined {
    return this.#peers.list()
  }

  openChannel(deviceId: string, channelType: string, params?: unknown): OutgoingChannel {
    return this.#peers.open(
      deviceId,
      channelType,
      params,
      this.#state === "connected" || this.#resumable()
    )
  }

  get state(): MachineConnectionState {
    return this.#state
  }

  start(): void {
    if (!this.#stopped) return
    this.#stopped = false
    this.#attempt = 0
    this.#connect()
  }

  stop(): void {
    this.#stopped = true
    this.#reconnectGeneration += 1
    this.#setState("stopped")
    this.#clearLivenessTimers()
    this.#dropOutbox()
    this.#discardResumeState()
    this.#peers.clear()
    const socket = this.#socket
    this.#socket = undefined
    socket?.close(1000, "stopping")
    this.#dropChannels()
  }

  #dropChannels(): void {
    this.#receiver.dropAll("peer-gone")
    this.#peers.dropChannels()
  }

  #setState(state: MachineConnectionState): void {
    if (this.#state === state) return
    this.#state = state
    this.options.onStateChange?.(state)
  }

  #connect(): void {
    const { credentials } = this.options
    if (this.#state !== "revoked") {
      this.#setState(this.#attempt === 0 ? "connecting" : "reconnecting")
    }
    const url = `${credentials.serverUrl.replace(/^http/, "ws")}/connect`
    const tunnelEndpointId = this.options.tunnelEndpointId
    const socket = this.options.socketFactory(url, {
      "x-api-key": credentials.apiKey,
      ...(tunnelEndpointId === undefined ? {} : { "x-codevisor-tunnel-endpoint": tunnelEndpointId })
    })
    this.#socket = socket
    this.#outbox = new RelayOutbox({
      send: (message) => {
        try {
          socket.send(message)
        } catch {}
      },
      scheduleTimeout: (callback, delayMs) => this.#scheduleTimeout(callback, delayMs),
      coalesceMs: this.options.relayCoalesceMs ?? 0
    })
    this.#cancelWelcomeTimeout = this.#scheduleTimeout(() => {
      this.#cancelWelcomeTimeout = undefined
      this.#forceReconnect(socket, { kind: "welcome-timeout" })
    }, 15_000)
    // oxlint-disable-next-line unicorn/prefer-add-event-listener
    socket.onopen = () => {
      if (this.#socket !== socket) return
      const device = {
        deviceId: credentials.deviceId,
        kind: "machine" as const,
        name: this.options.device.name,
        publicKey: credentials.publicKey,
        ...(this.options.device.os !== undefined ? { os: this.options.device.os } : {}),
        ...(this.options.device.icon !== undefined ? { icon: this.options.device.icon } : {}),
        ...(this.options.device.appVersion !== undefined
          ? { appVersion: this.options.device.appVersion }
          : {}),
        ...(this.options.device.serverId !== undefined
          ? { serverId: this.options.device.serverId }
          : {}),
        ...(tunnelEndpointId === undefined ? {} : { tunnelEndpointId }),
        ...releaseChannelField(this.options.device.releaseChannel?.())
      }
      try {
        socket.send(
          encodeCloudFrame({
            t: "hello",
            protocol: CLOUD_PROTOCOL_VERSION,
            device,
            features: [MACHINE_PEERS_FEATURE],
            ...(this.#resumeToken === undefined ? {} : { resume: this.#resumeToken })
          })
        )
      } catch {
        this.#forceReconnect(socket, { kind: "send-failed", phase: "hello" })
      }
    }
    // oxlint-disable-next-line unicorn/prefer-add-event-listener
    socket.onmessage = (data) => this.#onMessage(socket, data)
    // oxlint-disable-next-line unicorn/prefer-add-event-listener
    socket.onclose = (code) => this.#onSocketClosed(socket, code)
    socket.onrejected = (status) => this.#onUpgradeRejected(socket, status)
  }

  #onMessage(socket: CloudSocket, data: string | Uint8Array): void {
    if (this.#socket !== socket) return
    if (typeof data !== "string") return this.#onRelayBatch(data)

    const frame = decodeHubFrame(data)
    if (frame === undefined) return

    switch (frame.t) {
      case "welcome":
        this.#onWelcome(frame, socket)
        return
      case "pong":
        this.#onPong(socket)
        return
      case "error":
        this.#onHubError(frame)
        return
      case "peer-gone":
        this.#receiver.dropPeer(frame.peerId)
        return
      case "presence":
        this.#peers.presence(frame.machine)
        return
      case "machine-reset":
        this.#peers.reset(frame.machineId)
        return
      case "peer-devices":
        this.options.onPeerDevices?.(frame.devices)
        return
      case "inbox-item":
        this.options.onInboxItem?.(frame)
        return
    }
  }

  #onRelayBatch(data: Uint8Array): void {
    const envelopes = decodeRelayBatch(data)
    if (envelopes === undefined) return

    for (const envelope of envelopes) this.#routeRelay(envelope)
  }

  #routeRelay(envelope: WireRelayEnvelope): void {
    const header = parseHubToMachineRelayHeader(envelope.header)
    if (header !== undefined) {
      return this.#receiver.handleRelay(
        header.peerId,
        header.frame,
        envelope.payload,
        header.peerPublicKey,
        header.peerDeviceId,
        header.peerKind
      )
    }

    const answer = parseHubToAppRelayHeader(envelope.header)
    if (answer === undefined) return

    this.#peers.handleRelay(answer.machineId, answer.frame, envelope.payload)
  }

  #onWelcome(frame: HubFrame<"welcome">, socket: CloudSocket): void {
    this.#attempt = 0
    this.#cancelWelcomeTimeout?.()
    this.#cancelWelcomeTimeout = undefined

    const resume = this.#adoptConnection(frame)
    this.#settleRetained(resume.resumed)
    this.#peers.welcome(frame.machines)
    this.#setState("connected")
    this.options.onTunnelConfig?.(tunnelConfigOf(frame))
    this.options.onWelcome?.(resume)
    this.#scheduleHeartbeat(socket)
  }

  #adoptConnection(frame: HubFrame<"welcome">): WelcomeResume {
    this.#resumeToken = frame.resume
    const resumed = frame.resumed === true && frame.connectionId === this.#connectionId
    const retainedFrames = this.#retained.length
    this.#connectionId = frame.connectionId
    return { resumed, replayedFrames: resumed ? retainedFrames : 0 }
  }

  #settleRetained(resumed: boolean): void {
    if (resumed) return this.#replayRetained()
    this.#discardRetained()
  }

  #replayRetained(): void {
    const retained = this.#retained
    this.#retained = []
    this.#retainedBytes = 0
    for (const envelope of retained) this.#outbox?.push(envelope.header, envelope.payload)
  }

  #discardRetained(): void {
    this.#retained = []
    this.#retainedBytes = 0
    this.#dropChannels()
  }

  #onPong(socket: CloudSocket): void {
    if (this.#cancelPongTimeout === undefined) return

    this.#cancelPongTimeout()
    this.#cancelPongTimeout = undefined
    this.#scheduleHeartbeat(socket)
  }

  #onHubError(frame: HubFrame<"error">): void {
    if (frame.machineId !== undefined) this.#peers.hubError(frame.machineId, frame.channelId)
  }

  sendTunnelAddr(tunnel: CloudTunnelInfo): boolean {
    return this.#sendControl({ t: "tunnel-addr", tunnel })
  }

  ackInboxItems(itemIds: ReadonlyArray<string>): boolean {
    if (itemIds.length === 0) return true
    return this.#sendControl({ t: "inbox-ack", itemIds: [...itemIds] })
  }

  #sendControl(frame: MachineToHub): boolean {
    const socket = this.#socket
    if (socket === undefined || this.#state !== "connected") return false
    try {
      socket.send(encodeCloudFrame(frame))
      return true
    } catch {
      return false
    }
  }

  #scheduleHeartbeat(socket: CloudSocket): void {
    this.#cancelHeartbeat?.()
    this.#cancelHeartbeat = this.#scheduleTimeout(() => {
      this.#cancelHeartbeat = undefined
      if (this.#socket !== socket || this.#state !== "connected") return
      try {
        socket.send(encodeCloudFrame({ t: "ping" }))
      } catch {
        this.#forceReconnect(socket, { kind: "send-failed", phase: "heartbeat" })
        return
      }
      if (this.#socket !== socket) return
      this.#cancelPongTimeout?.()
      this.#cancelPongTimeout = this.#scheduleTimeout(() => {
        this.#cancelPongTimeout = undefined
        this.#forceReconnect(socket, { kind: "heartbeat-timeout" })
      }, 10_000)
    }, 30_000)
  }

  #onSocketClosed(socket: CloudSocket, code: number): void {
    if (this.#socket !== socket) return
    this.#socket = undefined
    this.#clearLivenessTimers()
    this.#suspendOrDrop()
    this.options.onDisconnect?.({ kind: "socket-closed", code })
    if (code === 4201) return this.#fail("revoked")
    if (code === 4200) return this.#fail("unsupported-protocol")
    this.#scheduleReconnect()
  }

  #onUpgradeRejected(socket: CloudSocket, status: number): void {
    if (this.#socket !== socket) return
    this.#socket = undefined
    this.#clearLivenessTimers()
    this.#suspendOrDrop()
    this.options.onDisconnect?.({ kind: "upgrade-rejected", status })
    if (isCredentialRejection(status)) return this.#fail("revoked")
    this.#scheduleReconnect()
  }

  #fail(state: "revoked" | "unsupported-protocol"): void {
    this.#discardResumeState()
    this.#dropChannels()
    this.#setState(state)
    if (state === "revoked") this.#connectAfter(REVOKED_RECHECK_MS)
  }

  #forceReconnect(socket: CloudSocket, reason: MachineDisconnectReason): void {
    if (this.#socket !== socket || this.#stopped) return
    this.#socket = undefined
    this.#clearLivenessTimers()
    this.#suspendOrDrop()
    this.options.onDisconnect?.(reason)
    try {
      if (socket.terminate !== undefined) socket.terminate()
      else socket.close(4001, reason.kind)
    } catch {}
    this.#scheduleReconnect()
  }

  #scheduleReconnect(): void {
    const delay = reconnectDelayMs(this.#attempt, this.options.random ?? Math.random)
    this.#attempt += 1
    this.#setState("reconnecting")
    this.#connectAfter(delay)
  }

  #connectAfter(delayMs: number): void {
    const schedule =
      this.options.scheduleReconnect ??
      ((callback: () => void, ms: number) => void setTimeout(callback, ms))
    const generation = ++this.#reconnectGeneration
    schedule(() => {
      if (!this.#stopped && generation === this.#reconnectGeneration) this.#connect()
    }, delayMs)
  }

  #scheduleTimeout(callback: () => void, delayMs: number): CancelTimeout {
    if (this.options.scheduleTimeout !== undefined) {
      return this.options.scheduleTimeout(callback, delayMs)
    }
    const timeout = setTimeout(callback, delayMs)
    return () => clearTimeout(timeout)
  }

  #clearLivenessTimers(): void {
    this.#cancelWelcomeTimeout?.()
    this.#cancelHeartbeat?.()
    this.#cancelPongTimeout?.()
    this.#cancelWelcomeTimeout = undefined
    this.#cancelHeartbeat = undefined
    this.#cancelPongTimeout = undefined
  }

  #dropOutbox(): void {
    this.#outbox?.clear()
    this.#outbox = undefined
  }

  #suspendOrDrop(): void {
    if (this.#resumable()) {
      /* v8 ignore next */
      const pending = this.#outbox?.drain() ?? []
      this.#outbox = undefined
      for (const envelope of pending) this.#retain(envelope.header, envelope.payload)
      return
    }
    this.#dropOutbox()
    this.#dropChannels()
  }

  #resumable(): boolean {
    return this.#resumeToken !== undefined && !this.#stopped
  }

  #discardResumeState(): void {
    this.#resumeToken = undefined
    this.#connectionId = undefined
    this.#retained = []
    this.#retainedBytes = 0
  }

  #retain(header: unknown, payload: Uint8Array): void {
    if (this.#retainedBytes + payload.byteLength > RESUME_RETAIN_CAP_BYTES) {
      this.#discardResumeState()
      this.#dropChannels()
      return
    }
    this.#retained.push({ header, payload })
    this.#retainedBytes += payload.byteLength
  }

  #sendEnvelope(
    header:
      | { peerId: string; frame: RelayFrameHeader }
      | { machineId: string; frame: RelayFrameHeader },
    payload: Uint8Array = new Uint8Array(0)
  ): void {
    if (this.#outbox !== undefined && this.#state === "connected") {
      this.#outbox.push(header, payload)
      return
    }
    if (this.#resumable()) {
      this.#retain(header, payload)
      return
    }
    this.#outbox?.push(header, payload)
  }
}
