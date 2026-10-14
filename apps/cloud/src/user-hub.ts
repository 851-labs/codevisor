import {
  CLOUD_PROTOCOL_VERSION,
  type CredentialCommand,
  decodeAppToHub,
  decodeMachineToHub,
  encodeCloudFrame,
  isoTimestamp,
  MACHINE_PEERS_FEATURE,
  type CloudMachinePresence
} from "@codevisor/api"
import { DurableObject } from "cloudflare:workers"

import { deleteHubAccount, storeCredentialCommand } from "./credential-storage.js"
import type { CloudEnv } from "./env.js"
import { deliverToMachine, deliverToPeer, type HubDeliveryPort } from "./hub-delivery.js"
import { HubMetrics } from "./hub-metrics.js"
import { abandonSession, announceExpired, type HubNoticesPort } from "./hub-notices.js"
import {
  listHubMachines,
  recordMachineOrigin,
  registerMachine,
  removeHubMachine,
  renameHubMachine
} from "./hub-registry.js"
import { HUB_MIGRATIONS, machinePresence, machineRow, type SocketAttachment } from "./hub-schema.js"
import { HubSockets } from "./hub-sockets.js"
import { hubTunnel } from "./hub-tunnel-events.js"
import { admitRelayMessage } from "./relay-admission.js"
import { routeAppRelay, routeMachineRelay, type RelayHubPort } from "./relay-routing.js"
import { DEFAULT_RESUME_GRACE_MS, ResumeSessions } from "./resume-sessions.js"

export const HUB_KIND_HEADER = "X-Codevisor-Kind"
export const HUB_DEVICE_ID_HEADER = "X-Codevisor-Device-Id"

export const CLOSE_INVALID_FRAME = 4000
export const CLOSE_UNSUPPORTED_PROTOCOL = 4200
export const CLOSE_REVOKED = 4201
export const CLOSE_SUPERSEDED = 4003
export const CLOSE_DELIVERY_FAILED = 4004

const MAX_FRAME_LENGTH = 64 * 1024

export class UserHub extends DurableObject<CloudEnv> {
  #accountDeleted = false
  readonly #resume: ResumeSessions
  readonly #net: HubSockets
  readonly #metrics = new HubMetrics()

  constructor(ctx: DurableObjectState, env: CloudEnv) {
    super(ctx, env)
    this.#net = new HubSockets(ctx)
    this.#resume = new ResumeSessions(
      ctx.storage.sql,
      Number(env.RESUME_GRACE_MS ?? "") || DEFAULT_RESUME_GRACE_MS
    )
    ctx.blockConcurrencyWhile(async () => {
      this.#accountDeleted = (await ctx.storage.get<boolean>("account_deleted")) === true
      const version = (await ctx.storage.get<number>("schema_version")) ?? 0
      for (let step = version; step < HUB_MIGRATIONS.length; step += 1) {
        ctx.storage.sql.exec(HUB_MIGRATIONS[step]!)
      }
      if (version !== HUB_MIGRATIONS.length) {
        await ctx.storage.put("schema_version", HUB_MIGRATIONS.length)
      }
    })
    ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair(
        encodeCloudFrame({ t: "ping" }),
        encodeCloudFrame({ t: "pong" })
      )
    )
  }

  async deleteAccount(): Promise<void> {
    this.#accountDeleted = true
    await deleteHubAccount(this.ctx, CLOSE_REVOKED)
  }

  listMachines(): CloudMachinePresence[] {
    return listHubMachines(this.#notices())
  }

  removeMachine(deviceId: string): boolean {
    return removeHubMachine(this.#notices(), deviceId, CLOSE_REVOKED)
  }

  renameMachine(deviceId: string, name: string): boolean {
    return renameHubMachine(this.#notices(), deviceId, name)
  }

  recordMachineOrigin(deviceId: string, addedBy: { deviceId: string; name: string }): void {
    recordMachineOrigin(this.ctx.storage.sql, deviceId, addedBy)
  }

  credentialCommand(id: string, owner: string, command: CredentialCommand) {
    return storeCredentialCommand(this.ctx.storage, this.#accountDeleted, id, owner, command)
  }

  override async fetch(request: Request): Promise<Response> {
    if (this.#accountDeleted) return new Response("Account deleted", { status: 401 })
    const kind = request.headers.get(HUB_KIND_HEADER)
    if ((kind !== "app" && kind !== "machine") || request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected authenticated websocket upgrade", { status: 400 })
    }
    const deviceId = request.headers.get(HUB_DEVICE_ID_HEADER) ?? undefined
    if (kind === "machine" && deviceId === undefined) {
      return new Response("machine connections require a device id", { status: 400 })
    }
    const pair = new WebSocketPair()
    const [client, server] = [pair[0], pair[1]]
    const connectionId = crypto.randomUUID()
    const tags = [kind, `conn:${connectionId}`]
    if (kind === "machine") tags.push(`machine:${deviceId}`)
    this.ctx.acceptWebSocket(server, tags)
    const attachment: SocketAttachment = { kind, connectionId, helloDone: false }
    if (deviceId !== undefined) attachment.deviceId = deviceId
    server.serializeAttachment(attachment)
    return new Response(null, { status: 101, webSocket: client })
  }

  override async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (this.#accountDeleted) return
    const attachment = this.#net.attachment(socket)
    if (attachment === undefined) {
      socket.close(CLOSE_INVALID_FRAME, "missing attachment")
      return
    }
    if (typeof message !== "string") {
      const envelopes = admitRelayMessage(message, attachment.helloDone)
      if (typeof envelopes === "string") {
        this.#net.error(socket, "invalid-frame", envelopes)
        return
      }
      this.#metrics.countRelay(attachment.connectionId, message.byteLength)
      if (attachment.kind === "app") {
        routeAppRelay(this.#relayPort(), socket, attachment, envelopes)
      } else {
        routeMachineRelay(this.#relayPort(), socket, attachment, envelopes)
      }
      return
    }
    if (message.length > MAX_FRAME_LENGTH) {
      this.#net.error(socket, "invalid-frame", "control frames must stay under the size limit")
      return
    }
    try {
      if (attachment.kind === "app") await this.#onAppFrame(socket, attachment, message)
      else await this.#onMachineFrame(socket, attachment, message)
    } catch {
      this.#net.error(socket, "invalid-frame", "frame failed to decode")
    }
  }

  override async webSocketClose(socket: WebSocket): Promise<void> {
    this.#onGone(socket)
  }

  override async webSocketError(socket: WebSocket): Promise<void> {
    this.#onGone(socket)
  }

  async #onAppFrame(
    socket: WebSocket,
    attachment: SocketAttachment,
    message: string
  ): Promise<void> {
    const frame = decodeAppToHub(message)
    if (frame.t === "ping") {
      socket.send(encodeCloudFrame({ t: "pong" }))
      return
    }
    if (frame.t === "hello") {
      if (frame.protocol !== CLOUD_PROTOCOL_VERSION) {
        this.#net.error(socket, "unsupported-protocol", "update Codevisor to use this relay")
        socket.close(CLOSE_UNSUPPORTED_PROTOCOL, "unsupported protocol")
        return
      }
      const { token, resumed } = await this.#adoptSession(attachment, "app", frame)
      if (this.#accountDeleted) return
      attachment.deviceId = frame.device.deviceId
      attachment.publicKey = frame.device.publicKey
      const tunnel = hubTunnel.appHello(this.ctx.storage.sql, this.#net, this.env, frame.device)
      this.#supersedeConnection(attachment.connectionId, socket)
      attachment.helloDone = true
      socket.serializeAttachment(attachment)
      if (
        !this.#net.send(
          socket,
          encodeCloudFrame({
            t: "welcome",
            protocol: CLOUD_PROTOCOL_VERSION,
            connectionId: attachment.connectionId,
            machines: this.listMachines(),
            resume: token,
            ...(resumed ? { resumed: true } : {}),
            ...tunnel
          })
        )
      ) {
        this.#retireUndeliverable(socket)
        return
      }
      if (resumed) this.#replayBuffers(socket, attachment.connectionId)
    }
  }

  async #onMachineFrame(
    socket: WebSocket,
    attachment: SocketAttachment,
    message: string
  ): Promise<void> {
    const frame = decodeMachineToHub(message)
    if (frame.t === "ping") {
      socket.send(encodeCloudFrame({ t: "pong" }))
      return
    }
    if (frame.t === "tunnel-addr") {
      return hubTunnel.addr(this.ctx.storage.sql, this.#net, attachment, frame.tunnel)
    }
    if (frame.t === "hello") {
      if (frame.protocol !== CLOUD_PROTOCOL_VERSION) {
        this.#net.error(
          socket,
          "unsupported-protocol",
          "update the Codevisor server to use this relay"
        )
        socket.close(CLOSE_UNSUPPORTED_PROTOCOL, "unsupported protocol")
        return
      }
      const deviceId = attachment.deviceId!
      const { token, resumed } = await this.#adoptSession(attachment, "machine", frame)
      if (this.#accountDeleted) return
      attachment.peerAware = frame.features?.includes(MACHINE_PEERS_FEATURE) === true
      const scope = hubTunnel.machineScope(this.env, frame.device)
      const sql = this.ctx.storage.sql
      attachment.machineGeneration = registerMachine(
        sql,
        deviceId,
        scope.device,
        attachment.peerAware
      )
      attachment.tunnel = scope.tunnelMachine
      attachment.publicKey = frame.device.publicKey
      for (const stale of this.#net.machine(deviceId)) {
        if (stale !== socket) this.#supersede(stale, "superseded by a newer connection")
      }
      attachment.helloDone = true
      socket.serializeAttachment(attachment)
      if (
        !this.#net.send(
          socket,
          encodeCloudFrame({
            t: "welcome",
            protocol: CLOUD_PROTOCOL_VERSION,
            connectionId: attachment.connectionId,
            resume: token,
            ...(resumed ? { resumed: true } : {}),
            ...(attachment.peerAware ? { machines: this.listMachines() } : {}),
            ...scope.welcome
          })
        )
      ) {
        this.#retireUndeliverable(socket)
        return
      }
      hubTunnel.sendPeerDevices(this.ctx.storage.sql, this.#net, socket)
      if (resumed) {
        this.#replayBuffers(socket, attachment.connectionId)
        return
      }
      for (const connectionId of this.#resume.deleteForMachineDevice(
        deviceId,
        attachment.connectionId
      )) {
        this.#net.broadcastToPeerMachines({ t: "peer-gone", peerId: connectionId })
      }
      this.#net.broadcastMachineNotice({ t: "machine-reset", machineId: deviceId })
      const row = machineRow(this.ctx.storage.sql, deviceId)
      if (row !== undefined)
        this.#net.broadcastMachineNotice({ t: "presence", machine: machinePresence(row, true) })
    }
  }

  async #adoptSession(
    attachment: SocketAttachment,
    kind: "app" | "machine",
    frame: { device: { deviceId: string; publicKey: string }; resume?: string | undefined }
  ): Promise<{ token: string; resumed: boolean }> {
    const adopted = await this.#resume.adoptOrRegister(
      attachment.connectionId,
      kind,
      frame.device,
      frame.resume
    )
    if (this.#accountDeleted) {
      this.#resume.delete(adopted.connectionId)
      return adopted
    }
    attachment.connectionId = adopted.connectionId
    this.#metrics.hello(kind, adopted.resumed, frame.resume !== undefined)
    return adopted
  }

  #replayBuffers(socket: WebSocket, connectionId: string): void {
    let replayed = 0
    for (const message of this.#resume.drainBuffers(connectionId)) {
      if (!this.#net.send(socket, message)) break
      replayed += 1
    }
    this.#metrics.replayed(connectionId, replayed)
  }

  #notices(): HubNoticesPort {
    return { net: this.#net, resume: this.#resume, sql: this.ctx.storage.sql }
  }

  #relayPort(): RelayHubPort {
    return {
      isKnownMachine: (machineId) => machineRow(this.ctx.storage.sql, machineId) !== undefined,
      acceptsMachinePeers: (machineId) =>
        machineRow(this.ctx.storage.sql, machineId)?.peer_aware === 1,
      deliverToMachine: (machineId, message) =>
        deliverToMachine(this.#deliveryPort(), machineId, message),
      deliverToPeer: (peerId, message) => deliverToPeer(this.#deliveryPort(), peerId, message),
      send: (socket, message) => this.#net.send(socket, message),
      error: (socket, code, message, context) => this.#net.error(socket, code, message, context)
    }
  }

  #deliveryPort(): HubDeliveryPort {
    return {
      ...this.#notices(),
      retire: (socket) => this.#retireUndeliverable(socket)
    }
  }

  #supersedeConnection(connectionId: string, replacement: WebSocket): void {
    for (const stale of this.#net.byConnectionId(connectionId)) {
      if (stale !== replacement) this.#supersede(stale, "superseded by a resumed connection")
    }
  }

  #supersede(socket: WebSocket, reason: string): void {
    this.#net.deactivate(socket)
    if (socket.readyState !== WebSocket.CLOSED) socket.close(CLOSE_SUPERSEDED, reason)
  }

  #retireUndeliverable(socket: WebSocket): void {
    this.#onGone(socket)
    if (socket.readyState !== WebSocket.CLOSED) {
      socket.close(CLOSE_DELIVERY_FAILED, "relay delivery failed")
    }
  }

  #onGone(socket: WebSocket): void {
    if (this.#accountDeleted) return
    const attachment = this.#net.attachment(socket)
    if (attachment === undefined || !attachment.helloDone) return
    this.#net.deactivate(socket)
    if (attachment.kind === "machine") {
      const activeGeneration = machineRow(
        this.ctx.storage.sql,
        attachment.deviceId!
      )?.active_generation
      if ((attachment.machineGeneration ?? 0) !== activeGeneration) return
    }
    const survivors = this.#net
      .byConnectionId(attachment.connectionId)
      .filter((candidate) => candidate !== socket && this.#net.isRoutable(candidate))
    if (survivors.length > 0) return
    if (attachment.kind === "machine") {
      this.ctx.storage.sql.exec(
        "UPDATE machines SET last_seen_at = ? WHERE device_id = ?",
        isoTimestamp(),
        attachment.deviceId!
      )
    }
    this.#metrics.sessionEnd(attachment)
    const deadline = this.#resume.markDisconnected(attachment.connectionId, Date.now())
    if (deadline !== undefined) {
      void this.#ensureAlarm(deadline)
      return
    }
    announceExpired(this.#notices(), {
      connection_id: attachment.connectionId,
      kind: attachment.kind,
      device_id: attachment.deviceId ?? "",
      public_key: attachment.publicKey ?? null,
      resume_token_hash: "",
      expires_at: null
    })
  }

  override async alarm(): Promise<void> {
    const now = Date.now()
    for (const session of this.#resume.expired(now)) {
      this.#metrics.resumeExpired(session)
      abandonSession(this.#notices(), session)
    }
    const next = this.#resume.nextExpiry()
    if (next !== undefined) await this.ctx.storage.setAlarm(Math.max(next, now + 250))
  }

  async #ensureAlarm(deadline: number): Promise<void> {
    const current = await this.ctx.storage.getAlarm()
    if (current === null || current > deadline) {
      await this.ctx.storage.setAlarm(deadline)
    }
  }
}
