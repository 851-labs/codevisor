import {
  CLOUD_PROTOCOL_VERSION,
  type CredentialCommand,
  decodeAppToHub,
  decodeMachineToHub,
  encodeCloudFrame,
  type HubToApp,
  type HubToMachine,
  isoTimestamp,
  MACHINE_PEERS_FEATURE,
  type MachineHello,
  type CloudMachinePresence
} from "@codevisor/api"
import { DurableObject } from "cloudflare:workers"

import { deleteHubAccount, storeCredentialCommand } from "./credential-storage.js"
import type { CloudEnv } from "./env.js"
import { deliverToMachine, deliverToPeer, type HubDeliveryPort } from "./hub-delivery.js"
import { HubInbox, type IngestOutcome, type SubscribeOutcome } from "./hub-inbox.js"
import { HubMetrics } from "./hub-metrics.js"
import { abandonSession, announceExpired, type HubNoticesPort } from "./hub-notices.js"
import {
  listHubMachines,
  recordMachineOrigin,
  registerMachine,
  removeHubMachine,
  updateHubMachine,
  type MachineUpdate
} from "./hub-registry.js"
import { HUB_MIGRATIONS, machinePresence, machineRow, type SocketAttachment } from "./hub-schema.js"
import { HubSockets } from "./hub-sockets.js"
import { hubTunnel } from "./hub-tunnel-events.js"
import {
  adoptAppIdentity,
  answerPing,
  completeHello,
  resumeFields,
  welcomeHead,
  type WelcomeMachines
} from "./hub-welcome.js"
import { inboxAckItemIds, type InboxRequest } from "./inbox-frames.js"
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
const APP_UPDATE_HINT = "update Codevisor to use this relay"
const MACHINE_UPDATE_HINT = "update the Codevisor server to use this relay"

type MachineHelloFrame = typeof MachineHello.Type
type TunnelWelcome = ReturnType<typeof hubTunnel.appHello>
type MachineTunnelScope = ReturnType<typeof hubTunnel.machineScope>

export class UserHub extends DurableObject<CloudEnv> {
  #accountDeleted = false
  readonly #resume: ResumeSessions
  readonly #net: HubSockets
  readonly #inbox: HubInbox
  readonly #metrics = new HubMetrics()

  constructor(ctx: DurableObjectState, env: CloudEnv) {
    super(ctx, env)
    this.#net = new HubSockets(ctx)
    this.#inbox = new HubInbox(ctx.storage.sql, this.#net)
    this.#resume = new ResumeSessions(
      ctx.storage.sql,
      Number(env.RESUME_GRACE_MS ?? "") || DEFAULT_RESUME_GRACE_MS
    )
    void ctx
      .blockConcurrencyWhile(async () => {
        this.#accountDeleted = (await ctx.storage.get<boolean>("account_deleted")) === true
        const version = (await ctx.storage.get<number>("schema_version")) ?? 0
        for (let step = version; step < HUB_MIGRATIONS.length; step += 1) {
          ctx.storage.sql.exec(HUB_MIGRATIONS[step]!)
        }
        if (version !== HUB_MIGRATIONS.length) {
          await ctx.storage.put("schema_version", HUB_MIGRATIONS.length)
        }
      })
      .catch((cause: unknown) => console.error("hub storage setup failed", cause))
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
    this.#inbox.forgetDevice(deviceId)
    return removeHubMachine(this.#notices(), deviceId, CLOSE_REVOKED)
  }

  updateMachine(deviceId: string, update: MachineUpdate): boolean {
    return updateHubMachine(this.#notices(), deviceId, update)
  }

  recordMachineOrigin(
    deviceId: string,
    addedBy: { deviceId: string; name: string },
    ephemeralProvider: string | null = null
  ): void {
    recordMachineOrigin(this.ctx.storage.sql, deviceId, addedBy, ephemeralProvider)
  }

  credentialCommand(id: string, owner: string, command: CredentialCommand) {
    return storeCredentialCommand(this.ctx.storage, this.#accountDeleted, id, owner, command)
  }

  subscribeInbox(inboxId: string, deviceId: string): SubscribeOutcome {
    return this.#inbox.subscribe(inboxId, deviceId)
  }

  unsubscribeInbox(inboxId: string, deviceId: string): void {
    this.#inbox.unsubscribe(inboxId, deviceId)
  }

  revokeInbox(inboxId: string): void {
    this.#inbox.revoke(inboxId)
  }

  async ingestInbox(inboxId: string, request: InboxRequest): Promise<IngestOutcome> {
    const outcome = this.#inbox.ingest(inboxId, request, Date.now())
    await this.#scheduleInboxSweep()
    return outcome
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
    if (frame.t === "ping") return answerPing(socket)
    if (frame.t !== "hello") return
    if (this.#rejectsProtocol(socket, frame.protocol, APP_UPDATE_HINT)) return
    const { token, resumed } = await this.#adoptSession(attachment, "app", frame)
    if (this.#accountDeleted) return

    adoptAppIdentity(attachment, frame)
    const tunnel = hubTunnel.appHello(this.ctx.storage.sql, this.#net, this.env, frame.device)
    this.#supersedeConnection(attachment.connectionId, socket)
    completeHello(socket, attachment)
    if (!this.#deliverWelcome(socket, this.#appWelcome(attachment, token, resumed, tunnel))) return

    if (resumed) this.#replayBuffers(socket, attachment.connectionId)
  }

  async #onMachineFrame(
    socket: WebSocket,
    attachment: SocketAttachment,
    message: string
  ): Promise<void> {
    const acked = inboxAckItemIds(message)
    if (acked !== undefined) return this.#inbox.acknowledge(attachment.deviceId!, acked)
    const frame = decodeMachineToHub(message)
    if (frame.t === "ping") return answerPing(socket)
    if (frame.t === "tunnel-addr") {
      return hubTunnel.addr(this.ctx.storage.sql, this.#net, attachment, frame.tunnel)
    }
    if (frame.t !== "hello") return
    if (this.#rejectsProtocol(socket, frame.protocol, MACHINE_UPDATE_HINT)) return
    const deviceId = attachment.deviceId!
    const { token, resumed } = await this.#adoptSession(attachment, "machine", frame)
    if (this.#accountDeleted) return

    const scope = this.#registerMachineConnection(attachment, deviceId, frame)
    this.#supersedeMachine(deviceId, socket)
    completeHello(socket, attachment)
    if (!this.#deliverWelcome(socket, this.#machineWelcome(attachment, token, resumed, scope))) {
      return
    }

    hubTunnel.sendPeerDevices(this.ctx.storage.sql, this.#net, socket)
    if (resumed) this.#replayBuffers(socket, attachment.connectionId)
    else this.#announceFreshMachine(deviceId, attachment)
    this.#inbox.flush(socket, deviceId)
  }

  #rejectsProtocol(socket: WebSocket, protocol: number, updateHint: string): boolean {
    if (protocol === CLOUD_PROTOCOL_VERSION) return false
    this.#net.error(socket, "unsupported-protocol", updateHint)
    socket.close(CLOSE_UNSUPPORTED_PROTOCOL, "unsupported protocol")
    return true
  }

  #registerMachineConnection(
    attachment: SocketAttachment,
    deviceId: string,
    frame: MachineHelloFrame
  ): MachineTunnelScope {
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
    return scope
  }

  #appWelcome(
    attachment: SocketAttachment,
    token: string,
    resumed: boolean,
    tunnel: TunnelWelcome
  ): HubToApp {
    return {
      ...welcomeHead(attachment.connectionId),
      machines: this.listMachines(),
      ...resumeFields(token, resumed),
      ...tunnel
    }
  }

  #machineWelcome(
    attachment: SocketAttachment,
    token: string,
    resumed: boolean,
    scope: MachineTunnelScope
  ): HubToMachine {
    return {
      ...welcomeHead(attachment.connectionId),
      ...resumeFields(token, resumed),
      ...this.#machinesForPeers(attachment.peerAware),
      ...scope.welcome
    }
  }

  #machinesForPeers(peerAware: boolean | undefined): WelcomeMachines {
    if (!peerAware) return {}
    return { machines: this.listMachines() }
  }

  #deliverWelcome(socket: WebSocket, welcome: HubToApp | HubToMachine): boolean {
    if (this.#net.send(socket, encodeCloudFrame(welcome))) return true
    this.#retireUndeliverable(socket)
    return false
  }

  #announceFreshMachine(deviceId: string, attachment: SocketAttachment): void {
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

  #supersedeMachine(deviceId: string, replacement: WebSocket): void {
    for (const stale of this.#net.machine(deviceId)) {
      if (stale !== replacement) this.#supersede(stale, "superseded by a newer connection")
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
      this.ctx.storage.sql.exec(markMachineSeenSql, isoTimestamp(), attachment.deviceId!)
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
    this.#inbox.sweep(now)
    const next = earliest(this.#resume.nextExpiry(), this.#inbox.nextExpiry())
    if (next !== undefined) await this.ctx.storage.setAlarm(Math.max(next, now + 250))
  }

  async #scheduleInboxSweep(): Promise<void> {
    const next = this.#inbox.nextExpiry()
    if (next !== undefined) await this.#ensureAlarm(next)
  }

  async #ensureAlarm(deadline: number): Promise<void> {
    const current = await this.ctx.storage.getAlarm()
    if (current === null || current > deadline) {
      await this.ctx.storage.setAlarm(deadline)
    }
  }
}

const earliest = (first: number | undefined, second: number | undefined): number | undefined => {
  if (first === undefined) return second
  if (second === undefined) return first
  return Math.min(first, second)
}

const markMachineSeenSql = "UPDATE machines SET last_seen_at = ? WHERE device_id = ?"
