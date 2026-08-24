// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import { encodeCloudFrame, type HubErrorCode, type HubToApp } from "@codevisor/api"
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

  /// send() that reports failure instead of throwing: a socket can be dead
  /// before its close event has fired, and callers must be able to react
  /// (report machine-offline / peer-gone) rather than crash frame handling.
  send(socket: WebSocket, encoded: string | Uint8Array): boolean {
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
      if (this.attachment(socket)?.helloDone === true) this.send(socket, encoded)
    }
  }
}
