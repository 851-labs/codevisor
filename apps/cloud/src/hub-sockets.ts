import {
  encodeCloudFrame,
  type HubErrorCode,
  type HubToApp,
  type HubToMachine
} from "@codevisor/api"

import type { SocketAttachment } from "./hub-schema.js"

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

  byConnectionId(connectionId: string): WebSocket[] {
    return this.ctx
      .getWebSockets()
      .filter((candidate) => this.attachment(candidate)?.connectionId === connectionId)
  }

  isRoutable(socket: WebSocket): boolean {
    return socket.readyState === WebSocket.OPEN && this.attachment(socket)?.helloDone === true
  }

  deactivate(socket: WebSocket): void {
    const attachment = this.attachment(socket)
    if (attachment === undefined || !attachment.helloDone) return
    attachment.helloDone = false
    try {
      socket.serializeAttachment(attachment)
    } catch {}
  }

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
      if (this.isRoutable(socket)) this.send(socket, encoded)
    }
  }

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

  broadcastToTunnelMachines(frame: HubToMachine): void {
    const encoded = encodeCloudFrame(frame)
    for (const socket of this.byTag("machine")) {
      const attachment = this.attachment(socket)
      if (attachment?.helloDone === true && attachment.tunnel === true && this.isRoutable(socket)) {
        this.send(socket, encoded)
      }
    }
  }

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
