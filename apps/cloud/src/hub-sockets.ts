import {
  encodeCloudFrame,
  type HubErrorCode,
  type HubToApp,
  type HubToMachine
} from "@codevisor/api"

import type { SocketAttachment } from "./hub-schema.js"

/// Socket bookkeeping over the DO's hibernatable WebSockets: tag lookups,
/// attachment access, and the failure-tolerant send/error/broadcast helpers
/// user-hub's frame handling composes.
export class HubSockets {
  constructor(private readonly ctx: DurableObjectState) {}

  attachment(socket: WebSocket): SocketAttachment | undefined {
    return (socket.deserializeAttachment() as SocketAttachment | null) ?? undefined
  }

  byTag(tag: string): WebSocket[] {
    return this.ctx.getWebSockets(tag)
  }

  machine(deviceId: string): WebSocket[] {
    return this.byTag(`machine:${deviceId}`)
  }

  /// Attachment scan, not the conn: tag — a resumed socket adopts its
  /// predecessor's connectionId, and accept-time tags cannot change.
  byConnectionId(connectionId: string): WebSocket[] {
    return this.ctx
      .getWebSockets()
      .filter((candidate) => this.attachment(candidate)?.connectionId === connectionId)
  }

  isRoutable(socket: WebSocket): boolean {
    return socket.readyState === WebSocket.OPEN && this.attachment(socket)?.helloDone === true
  }

  /// Removes a socket from routing before close delivery catches up. The
  /// attachment is durable, so a hibernation boundary cannot resurrect it.
  deactivate(socket: WebSocket): void {
    const attachment = this.attachment(socket)
    if (attachment === undefined || !attachment.helloDone) return
    attachment.helloDone = false
    try {
      socket.serializeAttachment(attachment)
    } catch {
      // A close can win between attachment lookup and persistence. Routing
      // still excludes it by readyState, and disconnect state is idempotent.
    }
  }

  /// Cloudflare silently discards send() on CLOSING/CLOSED sockets, so the
  /// ready-state check is part of delivery acknowledgement, not an optional
  /// optimization. Throws still cover a socket dying between check and send.
  send(socket: WebSocket, encoded: string | Uint8Array): boolean {
    if (socket.readyState !== WebSocket.OPEN) return false
    try {
      socket.send(encoded)
      return true
    } catch {
      return false
    }
  }

  error(
    socket: WebSocket,
    code: HubErrorCode,
    message: string,
    context: { machineId?: string; channelId?: string } = {}
  ): void {
    socket.send(encodeCloudFrame({ t: "error", code, message, ...context }))
  }

  broadcastToApps(frame: HubToApp): void {
    const encoded = encodeCloudFrame(frame)
    for (const socket of this.byTag("app")) {
      // A dead socket must not abort the broadcast for the remaining apps;
      // its own close event will clean it up.
      if (this.isRoutable(socket)) this.send(socket, encoded)
    }
  }

  /// Machine sockets that advertised MACHINE_PEERS_FEATURE: they may hold
  /// channels to other machines, so they follow presence like apps do.
  peerAwareMachines(): WebSocket[] {
    return this.byTag("machine").filter(
      (socket) => this.isRoutable(socket) && this.attachment(socket)?.peerAware === true
    )
  }

  broadcastToPeerMachines(frame: HubToMachine, exceptDeviceId?: string): void {
    const encoded = encodeCloudFrame(frame)
    for (const socket of this.peerAwareMachines()) {
      if (exceptDeviceId === undefined || this.attachment(socket)?.deviceId !== exceptDeviceId) {
        this.send(socket, encoded)
      }
    }
  }

  /// Machine presence-plane frames (presence, machine-reset, machine-offline)
  /// go to every observer: apps and peer-aware machines alike — except the
  /// machine the notice is about.
  broadcastMachineNotice(frame: HubToApp & HubToMachine): void {
    this.broadcastToApps(frame)
    const subject =
      frame.t === "presence"
        ? frame.machine.deviceId
        : "machineId" in frame
          ? frame.machineId
          : undefined
    this.broadcastToPeerMachines(frame, subject)
  }
}
