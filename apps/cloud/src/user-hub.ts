import { DurableObject } from "cloudflare:workers"
// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import {
  CLOUD_PROTOCOL_VERSION,
  decodeAppToHub,
  decodeMachineToHub,
  decodeRelayEnvelopes,
  encodeCloudFrame,
  isoTimestamp,
  MAX_RELAY_MESSAGE_BYTES,
  type CloudMachinePresence,
  type WireRelayEnvelope
} from "@codevisor/api"
import type { CloudEnv } from "./env.js"
import {
  deliverToMachine,
  deliverToPeer,
  hasRoutableMachineSocket,
  type HubDeliveryPort
} from "./hub-delivery.js"
import { HubMetrics } from "./hub-metrics.js"
import { announceExpired, type HubNoticesPort } from "./hub-notices.js"
import {
  HUB_MIGRATIONS,
  machinePresence,
  machineRow,
  machineRows,
  type SocketAttachment
} from "./hub-schema.js"
import { HubSockets } from "./hub-sockets.js"
import { routeAppRelay, routeMachineRelay, type RelayHubPort } from "./relay-routing.js"
import { DEFAULT_RESUME_GRACE_MS, ResumeSessions } from "./resume-sessions.js"

/// One hub per account (`getByName(userId)`): the rendezvous point every one
/// of the user's app and machine sockets dials into. The hub is a dumb router:
/// - hello/presence frames are understood and answered;
/// - relay frames have their addressing rewritten (machineId ↔ peerId) and
///   their sealed payloads forwarded untouched — content is end-to-end
///   encrypted between devices and never readable here.
///
/// Authentication happens in the Worker before the request reaches the DO
/// (session token for apps, api key for machines); the DO trusts the
/// X-Codevisor-* headers the Worker attaches.
///
/// All sockets use the hibernation API, so an account with idle machines
/// costs nothing between frames. In-memory state is cache only — everything
/// durable lives in the DO's SQLite and socket attachments (≤16 KB).

export const HUB_KIND_HEADER = "X-Codevisor-Kind"
export const HUB_DEVICE_ID_HEADER = "X-Codevisor-Device-Id"

/// Close codes (4xxx = application-defined). Clients treat 42xx as fatal
/// (do not reconnect with the same credentials/protocol) and everything else
/// as transient.
export const CLOSE_INVALID_FRAME = 4000
export const CLOSE_UNSUPPORTED_PROTOCOL = 4200
export const CLOSE_REVOKED = 4201
export const CLOSE_HELLO_TIMEOUT = 4002
/// A newer socket completed hello for the same machine device id. The older
/// socket is a zombie (half-open, or a superseded process) — routing to it
/// would black-hole relay traffic. Non-fatal: a legitimately superseded
/// process may reconnect and take over again.
export const CLOSE_SUPERSEDED = 4003
/// A socket failed an actual relay write before its close callback arrived.
/// Retiring it immediately starts resume grace and makes the next hello a
/// normal transient reconnect.
export const CLOSE_DELIVERY_FAILED = 4004

const MAX_FRAME_LENGTH = 64 * 1024

export class UserHub extends DurableObject<CloudEnv> {
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
      const version =
        (await ctx.storage.get<number>("schema_version")) ??
        // Fresh instance — run every migration below.
        0
      for (let step = version; step < HUB_MIGRATIONS.length; step += 1) {
        ctx.storage.sql.exec(HUB_MIGRATIONS[step]!)
      }
      if (version !== HUB_MIGRATIONS.length) {
        await ctx.storage.put("schema_version", HUB_MIGRATIONS.length)
      }
    })
    // Keep protocol-level keepalives from waking a hibernated hub.
    ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair(
        encodeCloudFrame({ t: "ping" }),
        encodeCloudFrame({ t: "pong" })
      )
    )
  }

  // -- Worker-facing RPC -----------------------------------------------------

  /// Registry + live presence; used by the REST surface and app settings.
  listMachines(): CloudMachinePresence[] {
    // Machines in their resume grace window count as online: their
    // disconnect was never announced, and a resume makes it moot.
    const online = this.#resume.machineDeviceIdsInGrace(Date.now())
    const rows = machineRows(this.ctx.storage.sql)
    for (const row of rows) {
      if (hasRoutableMachineSocket(this.#net, row.device_id, row.active_generation)) {
        online.add(row.device_id)
      }
    }
    return rows.map((row) => machinePresence(row, online.has(row.device_id)))
  }

  /// Disconnects and forgets a machine. The Worker revokes the api key first;
  /// this makes the hub side immediate rather than next-auth-failure.
  removeMachine(deviceId: string): boolean {
    const existing = machineRow(this.ctx.storage.sql, deviceId)
    if (existing === undefined) return false
    this.ctx.storage.sql.exec("DELETE FROM machines WHERE device_id = ?", deviceId)
    this.#resume.deleteForMachineDevice(deviceId)
    for (const socket of this.#net.machine(deviceId)) {
      socket.close(CLOSE_REVOKED, "machine disconnected from account")
    }
    this.#net.broadcastToApps({
      t: "presence",
      machine: machinePresence({ ...existing, last_seen_at: isoTimestamp() }, false)
    })
    return true
  }

  renameMachine(deviceId: string, name: string): boolean {
    const updated = this.ctx.storage.sql.exec(
      "UPDATE machines SET name = ? WHERE device_id = ?",
      name,
      deviceId
    ).rowsWritten
    if (updated === 0) return false
    const row = machineRow(this.ctx.storage.sql, deviceId)
    if (row !== undefined) {
      this.#net.broadcastToApps({
        t: "presence",
        machine: machinePresence(
          row,
          hasRoutableMachineSocket(this.#net, deviceId, row.active_generation) ||
            this.#resume.machineGraceSession(deviceId, Date.now()) !== undefined
        )
      })
    }
    return true
  }

  // -- WebSocket lifecycle ---------------------------------------------------

  override async fetch(request: Request): Promise<Response> {
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
    const attachment = this.#net.attachment(socket)
    if (attachment === undefined) {
      socket.close(CLOSE_INVALID_FRAME, "missing attachment")
      return
    }
    // Binary messages are relay envelope batches; text messages are the rare
    // JSON control frames (hello/ping).
    if (typeof message !== "string") {
      if (message.byteLength > MAX_RELAY_MESSAGE_BYTES) {
        this.#net.error(socket, "invalid-frame", "relay message exceeds the size limit")
        return
      }
      if (!attachment.helloDone) {
        this.#net.error(socket, "invalid-frame", "hello required before relaying")
        return
      }
      let envelopes: WireRelayEnvelope[]
      try {
        envelopes = decodeRelayEnvelopes(new Uint8Array(message))
      } catch {
        this.#net.error(socket, "invalid-frame", "malformed relay message")
        return
      }
      this.#metrics.countRelay(attachment.connectionId, message.byteLength)
      if (attachment.kind === "app") {
        routeAppRelay(this.#relayPort(), socket, attachment, envelopes)
      } else {
        routeMachineRelay(this.#relayPort(), socket, attachment.deviceId!, envelopes)
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

  // -- Frame handling --------------------------------------------------------

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
      attachment.deviceId = frame.device.deviceId
      attachment.publicKey = frame.device.publicKey
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
            ...(resumed ? { resumed: true } : {})
          })
        )
      ) {
        this.#retireUndeliverable(socket)
        return
      }
      // A resumed app never looked gone; replay what arrived meanwhile.
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
      const now = isoTimestamp()
      const generation = (machineRow(this.ctx.storage.sql, deviceId)?.active_generation ?? 0) + 1
      this.ctx.storage.sql.exec(
        `INSERT INTO machines
           (device_id, name, os, app_version, public_key, last_seen_at, active_generation)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(device_id) DO UPDATE SET
           name = excluded.name,
           os = excluded.os,
           app_version = excluded.app_version,
           public_key = excluded.public_key,
           last_seen_at = excluded.last_seen_at,
           active_generation = excluded.active_generation`,
        deviceId,
        frame.device.name,
        frame.device.os ?? null,
        frame.device.appVersion ?? null,
        frame.device.publicKey,
        now,
        generation
      )
      attachment.machineGeneration = generation
      // Install the durable generation before demoting the predecessor. From
      // this point routing can select only this socket, even if close delivery
      // for an older half-open connection is delayed.
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
            ...(resumed ? { resumed: true } : {})
          })
        )
      ) {
        this.#retireUndeliverable(socket)
        return
      }
      if (resumed) {
        // Nobody was told the machine left: skip the reset/presence noise
        // and replay what apps sent meanwhile.
        this.#replayBuffers(socket, attachment.connectionId)
        return
      }
      // A fresh hello means the machine process restarted: any grace session
      // for this device is moot (its channels are gone regardless).
      this.#resume.deleteForMachineDevice(deviceId, attachment.connectionId)
      // Channel state on the machine is in-memory and did not survive the
      // restart: tell apps to reset their channels toward this machine
      // *before* announcing it online, so re-opens park briefly and then
      // dispatch to the fresh socket instead of racing the teardown.
      this.#net.broadcastToApps({ t: "machine-reset", machineId: deviceId })
      const row = machineRow(this.ctx.storage.sql, deviceId)
      if (row !== undefined)
        this.#net.broadcastToApps({ t: "presence", machine: machinePresence(row, true) })
    }
  }

  /// Session resume at hello time: adopt or register, superseding any
  /// half-open zombie socket that still holds the restored identity.
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
    attachment.connectionId = adopted.connectionId
    this.#metrics.hello(kind, adopted.resumed, frame.resume !== undefined)
    return adopted
  }

  /// Hands a resumed connection everything relayed while it was away.
  #replayBuffers(socket: WebSocket, connectionId: string): void {
    let replayed = 0
    for (const message of this.#resume.drainBuffers(connectionId)) {
      if (!this.#net.send(socket, message)) break
      replayed += 1
    }
    this.#metrics.replayed(connectionId, replayed)
  }

  /// Dependencies for the deferred death notices (hub-notices.ts).
  #notices(): HubNoticesPort {
    return { net: this.#net, resume: this.#resume, sql: this.ctx.storage.sql }
  }

  /// The narrow surface relay routing (relay-routing.ts) uses to reach this
  /// hub's sockets and registry.
  #relayPort(): RelayHubPort {
    return {
      isKnownMachine: (machineId) => machineRow(this.ctx.storage.sql, machineId) !== undefined,
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
    const attachment = this.#net.attachment(socket)
    if (attachment === undefined || !attachment.helloDone) return
    // Make close/error callbacks idempotent and exclude this socket from all
    // routing before changing session state.
    this.#net.deactivate(socket)
    if (attachment.kind === "machine") {
      const activeGeneration = machineRow(
        this.ctx.storage.sql,
        attachment.deviceId!
      )?.active_generation
      if ((attachment.machineGeneration ?? 0) !== activeGeneration) return
    }
    // A newer socket already adopted this identity (resume supersede, or the
    // one-live-socket-per-machine rule): this close is not a departure.
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
    // One traffic summary per socket leg; a resumed connection accumulates
    // (and later reports) a fresh run under the same connection id.
    this.#metrics.sessionEnd(attachment)
    // Start the resume grace window instead of announcing death; the alarm
    // delivers the deferred peer-gone/offline signals only if nobody resumes.
    const deadline = this.#resume.markDisconnected(attachment.connectionId, Date.now())
    if (deadline !== undefined) {
      void this.#ensureAlarm(deadline)
      return
    }
    // No resumable session (it was abandoned or removed): announce now.
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
      this.#resume.delete(session.connection_id)
      this.#metrics.resumeExpired(session)
      announceExpired(this.#notices(), session)
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
