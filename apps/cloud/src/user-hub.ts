import { DurableObject } from "cloudflare:workers"
// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import {
  CLOUD_PROTOCOL_VERSION,
  decodeAppToHub,
  decodeMachineToHub,
  encodeCloudFrame,
  isoTimestamp,
  type CloudMachinePresence,
  type HubErrorCode,
  type HubToApp,
  type HubToMachine
} from "@codevisor/api"
import type { CloudEnv } from "./env.js"

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

/// Refuse relay frames larger than this many UTF-16 code units (~2 MiB of
/// JSON): far above coalesced terminal output, far below DO message limits.
const MAX_FRAME_LENGTH = 2 * 1024 * 1024

interface SocketAttachment {
  kind: "app" | "machine"
  connectionId: string
  /// Machine sockets: the registered device id. App sockets: absent until
  /// hello, then the app's self-assigned device id.
  deviceId?: string
  /// App sockets: static public key from hello, attached to `open` relays so
  /// machines can authenticate the channel opener.
  publicKey?: string
  helloDone: boolean
}

interface MachineRow extends Record<string, SqlStorageValue> {
  device_id: string
  name: string
  os: string | null
  app_version: string | null
  public_key: string
  last_seen_at: string
}

const MIGRATIONS: readonly string[] = [
  `CREATE TABLE machines (
     device_id TEXT PRIMARY KEY,
     name TEXT NOT NULL,
     os TEXT,
     app_version TEXT,
     public_key TEXT NOT NULL,
     last_seen_at TEXT NOT NULL
   )`
]

export class UserHub extends DurableObject<CloudEnv> {
  constructor(ctx: DurableObjectState, env: CloudEnv) {
    super(ctx, env)
    ctx.blockConcurrencyWhile(async () => {
      const version =
        (await ctx.storage.get<number>("schema_version")) ??
        // Fresh instance — run every migration below.
        0
      for (let step = version; step < MIGRATIONS.length; step += 1) {
        ctx.storage.sql.exec(MIGRATIONS[step]!)
      }
      if (version !== MIGRATIONS.length) {
        await ctx.storage.put("schema_version", MIGRATIONS.length)
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
    const online = new Set(
      this.#sockets("machine")
        .map((socket) => this.#attachment(socket)?.deviceId)
        .filter((id): id is string => id !== undefined)
    )
    return this.#machineRows().map((row) => this.#presence(row, online.has(row.device_id)))
  }

  /// Disconnects and forgets a machine. The Worker revokes the api key first;
  /// this makes the hub side immediate rather than next-auth-failure.
  removeMachine(deviceId: string): boolean {
    const existing = this.ctx.storage.sql
      .exec<MachineRow>("SELECT * FROM machines WHERE device_id = ?", deviceId)
      .toArray()
    if (existing.length === 0) return false
    this.ctx.storage.sql.exec("DELETE FROM machines WHERE device_id = ?", deviceId)
    for (const socket of this.#machineSockets(deviceId)) {
      socket.close(CLOSE_REVOKED, "machine disconnected from account")
    }
    this.#broadcastToApps({
      t: "presence",
      machine: this.#presence({ ...existing[0]!, last_seen_at: isoTimestamp() }, false)
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
    const row = this.#machineRow(deviceId)
    if (row !== undefined) {
      this.#broadcastToApps({
        t: "presence",
        machine: this.#presence(row, this.#machineSockets(deviceId).length > 0)
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
    const attachment = this.#attachment(socket)
    if (attachment === undefined) {
      socket.close(CLOSE_INVALID_FRAME, "missing attachment")
      return
    }
    if (typeof message !== "string" || message.length > MAX_FRAME_LENGTH) {
      this.#error(socket, "invalid-frame", "frames must be JSON text under the size limit")
      return
    }
    try {
      if (attachment.kind === "app") this.#onAppFrame(socket, attachment, message)
      else this.#onMachineFrame(socket, attachment, message)
    } catch {
      this.#error(socket, "invalid-frame", "frame failed to decode")
    }
  }

  override async webSocketClose(socket: WebSocket): Promise<void> {
    this.#onGone(socket)
  }

  override async webSocketError(socket: WebSocket): Promise<void> {
    this.#onGone(socket)
  }

  // -- Frame handling --------------------------------------------------------

  #onAppFrame(socket: WebSocket, attachment: SocketAttachment, message: string): void {
    const frame = decodeAppToHub(message)
    if (frame.t === "ping") {
      socket.send(encodeCloudFrame({ t: "pong" }))
      return
    }
    if (frame.t === "hello") {
      if (frame.protocol !== CLOUD_PROTOCOL_VERSION) {
        this.#error(socket, "unsupported-protocol", "update Codevisor to use this relay")
        socket.close(CLOSE_UNSUPPORTED_PROTOCOL, "unsupported protocol")
        return
      }
      attachment.deviceId = frame.device.deviceId
      attachment.publicKey = frame.device.publicKey
      attachment.helloDone = true
      socket.serializeAttachment(attachment)
      socket.send(
        encodeCloudFrame({
          t: "welcome",
          protocol: CLOUD_PROTOCOL_VERSION,
          connectionId: attachment.connectionId,
          machines: this.listMachines()
        })
      )
      return
    }
    // relay
    if (!attachment.helloDone) {
      this.#error(socket, "invalid-frame", "hello required before relaying")
      return
    }
    const machineSocket = this.#machineSockets(frame.machineId).find(
      (candidate) => this.#attachment(candidate)?.helloDone === true
    )
    if (machineSocket === undefined) {
      const known = this.#machineRow(frame.machineId) !== undefined
      this.#error(
        socket,
        known ? "machine-offline" : "unknown-machine",
        known ? "machine is not connected" : "no such machine on this account",
        { machineId: frame.machineId, channelId: frame.frame.channelId }
      )
      return
    }
    const relayed: HubToMachine = {
      t: "relay",
      peerId: attachment.connectionId,
      frame: frame.frame,
      ...(frame.frame.t === "open" && attachment.publicKey !== undefined
        ? { peerPublicKey: attachment.publicKey }
        : {})
    }
    if (!this.#send(machineSocket, encodeCloudFrame(relayed))) {
      // The chosen machine socket is dead but its close event has not fired
      // yet. Report it like any other offline machine instead of dropping
      // the frame silently.
      console.warn("relay to machine failed: socket dead before close event", {
        machineId: frame.machineId,
        channelId: frame.frame.channelId
      })
      this.#error(socket, "machine-offline", "machine relay socket failed", {
        machineId: frame.machineId,
        channelId: frame.frame.channelId
      })
    }
  }

  #onMachineFrame(socket: WebSocket, attachment: SocketAttachment, message: string): void {
    const frame = decodeMachineToHub(message)
    if (frame.t === "ping") {
      socket.send(encodeCloudFrame({ t: "pong" }))
      return
    }
    if (frame.t === "hello") {
      if (frame.protocol !== CLOUD_PROTOCOL_VERSION) {
        this.#error(socket, "unsupported-protocol", "update the Codevisor server to use this relay")
        socket.close(CLOSE_UNSUPPORTED_PROTOCOL, "unsupported protocol")
        return
      }
      const deviceId = attachment.deviceId!
      const now = isoTimestamp()
      this.ctx.storage.sql.exec(
        `INSERT INTO machines (device_id, name, os, app_version, public_key, last_seen_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(device_id) DO UPDATE SET
           name = excluded.name,
           os = excluded.os,
           app_version = excluded.app_version,
           public_key = excluded.public_key,
           last_seen_at = excluded.last_seen_at`,
        deviceId,
        frame.device.name,
        frame.device.os ?? null,
        frame.device.appVersion ?? null,
        frame.device.publicKey,
        now
      )
      attachment.helloDone = true
      socket.serializeAttachment(attachment)
      socket.send(
        encodeCloudFrame({
          t: "welcome",
          protocol: CLOUD_PROTOCOL_VERSION,
          connectionId: attachment.connectionId
        })
      )
      // One live socket per machine device. Older sockets are zombies
      // (half-open TCP, or a superseded process): app→machine routing picks
      // an arbitrary socket, so a lingering zombie would black-hole traffic —
      // and its continued presence would suppress the offline broadcast when
      // the socket that actually carries traffic dies. Closing them here also
      // keeps their #onGone from flapping presence (this socket is live).
      for (const stale of this.#machineSockets(deviceId)) {
        if (stale !== socket) stale.close(CLOSE_SUPERSEDED, "superseded by a newer connection")
      }
      // Channel state on the machine is in-memory and did not survive the
      // (re)connect: tell apps to reset their channels toward this machine
      // *before* announcing it online, so re-opens park briefly and then
      // dispatch to the fresh socket instead of racing the teardown.
      this.#broadcastToApps({ t: "machine-reset", machineId: deviceId })
      const row = this.#machineRow(deviceId)
      if (row !== undefined)
        this.#broadcastToApps({ t: "presence", machine: this.#presence(row, true) })
      return
    }
    // relay
    if (!attachment.helloDone) {
      this.#error(socket, "invalid-frame", "hello required before relaying")
      return
    }
    const peer = this.#sockets(`conn:${frame.peerId}`).find(
      (candidate) => this.#attachment(candidate)?.kind === "app"
    )
    if (peer === undefined) {
      // The app socket vanished; tell the machine so it can drop channels.
      socket.send(encodeCloudFrame({ t: "peer-gone", peerId: frame.peerId }))
      return
    }
    const relayed: HubToApp = {
      t: "relay",
      machineId: attachment.deviceId!,
      frame: frame.frame
    }
    if (!this.#send(peer, encodeCloudFrame(relayed))) {
      // The app socket is dead but its close event has not fired yet: tell
      // the machine now, exactly as if the peer were already known-gone.
      console.warn("relay to app failed: socket dead before close event", {
        peerId: frame.peerId,
        channelId: frame.frame.channelId
      })
      this.#send(socket, encodeCloudFrame({ t: "peer-gone", peerId: frame.peerId }))
    }
  }

  #onGone(socket: WebSocket): void {
    const attachment = this.#attachment(socket)
    if (attachment === undefined || !attachment.helloDone) return
    if (attachment.kind === "machine") {
      const deviceId = attachment.deviceId!
      const now = isoTimestamp()
      this.ctx.storage.sql.exec(
        "UPDATE machines SET last_seen_at = ? WHERE device_id = ?",
        now,
        deviceId
      )
      const stillConnected = this.#machineSockets(deviceId).some(
        (candidate) => candidate !== socket && this.#attachment(candidate)?.helloDone === true
      )
      if (!stillConnected) {
        const row = this.#machineRow(deviceId)
        if (row !== undefined) {
          this.#broadcastToApps({ t: "presence", machine: this.#presence(row, false) })
        }
        // Also broadcast the machine-offline error apps already understand
        // from failed relay attempts: their channels toward this machine are
        // dead, and a receive-only stream would otherwise never find out
        // (it sends nothing, so it can never provoke the reactive error).
        this.#broadcastToApps({
          t: "error",
          code: "machine-offline",
          message: "machine disconnected from the relay",
          machineId: deviceId
        })
      }
      return
    }
    // App gone: let machines tear down that peer's channels promptly.
    const gone: HubToMachine = { t: "peer-gone", peerId: attachment.connectionId }
    for (const machineSocket of this.#sockets("machine")) {
      if (this.#attachment(machineSocket)?.helloDone === true) {
        machineSocket.send(encodeCloudFrame(gone))
      }
    }
  }

  // -- Helpers ---------------------------------------------------------------

  #attachment(socket: WebSocket): SocketAttachment | undefined {
    return (socket.deserializeAttachment() as SocketAttachment | null) ?? undefined
  }

  #sockets(tag: string): WebSocket[] {
    return this.ctx.getWebSockets(tag)
  }

  #machineSockets(deviceId: string): WebSocket[] {
    return this.#sockets(`machine:${deviceId}`)
  }

  #machineRows(): MachineRow[] {
    return this.ctx.storage.sql
      .exec<MachineRow>("SELECT * FROM machines ORDER BY name, device_id")
      .toArray()
  }

  #machineRow(deviceId: string): MachineRow | undefined {
    return this.ctx.storage.sql
      .exec<MachineRow>("SELECT * FROM machines WHERE device_id = ?", deviceId)
      .toArray()[0]
  }

  #presence(row: MachineRow, online: boolean): CloudMachinePresence {
    return {
      deviceId: row.device_id,
      name: row.name,
      ...(row.os !== null ? { os: row.os } : {}),
      ...(row.app_version !== null ? { appVersion: row.app_version } : {}),
      publicKey: row.public_key,
      online,
      lastSeenAt: row.last_seen_at
    }
  }

  #broadcastToApps(frame: HubToApp): void {
    const encoded = encodeCloudFrame(frame)
    for (const socket of this.#sockets("app")) {
      // A dead socket must not abort the broadcast for the remaining apps;
      // its own close event will clean it up.
      if (this.#attachment(socket)?.helloDone === true) this.#send(socket, encoded)
    }
  }

  /// send() that reports failure instead of throwing: a socket can be dead
  /// before its close event has fired, and callers must be able to react
  /// (report machine-offline / peer-gone) rather than crash frame handling.
  #send(socket: WebSocket, encoded: string): boolean {
    try {
      socket.send(encoded)
      return true
    } catch {
      return false
    }
  }

  #error(
    socket: WebSocket,
    code: HubErrorCode,
    message: string,
    context: { machineId?: string; channelId?: string } = {}
  ): void {
    socket.send(encodeCloudFrame({ t: "error", code, message, ...context }))
  }
}
