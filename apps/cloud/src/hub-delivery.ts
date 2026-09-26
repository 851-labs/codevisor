import { bufferOrAbandon, type HubNoticesPort } from "./hub-notices.js"
import { machineRow } from "./hub-schema.js"
import type { HubSockets } from "./hub-sockets.js"

/// The relay delivery policy kept separate from frame rewriting: select only
/// the current machine generation, retry every eligible socket, retire failed
/// transports synchronously, then fall back to the bounded resume buffer.

export interface HubDeliveryPort extends HubNoticesPort {
  retire(socket: WebSocket): void
}

export const machineSocketsForGeneration = (
  net: HubSockets,
  deviceId: string,
  generation: number
): WebSocket[] =>
  net.machine(deviceId).filter((socket) => {
    const attachment = net.attachment(socket)
    return attachment?.helloDone === true && (attachment.machineGeneration ?? 0) === generation
  })

export const hasRoutableMachineSocket = (
  net: HubSockets,
  deviceId: string,
  generation: number
): boolean =>
  machineSocketsForGeneration(net, deviceId, generation).some((socket) => net.isRoutable(socket))

export const deliverToMachine = (
  port: HubDeliveryPort,
  machineId: string,
  message: Uint8Array
): boolean => {
  const row = machineRow(port.sql, machineId)
  if (row === undefined) return false
  for (const socket of machineSocketsForGeneration(port.net, machineId, row.active_generation)) {
    if (port.net.send(socket, message)) return true
    port.retire(socket)
  }
  const session = port.resume.machineGraceSession(machineId, Date.now())
  return session === undefined ? false : bufferOrAbandon(port, session, message)
}

export const deliverToPeer = (
  port: HubDeliveryPort,
  peerId: string,
  message: Uint8Array
): boolean => {
  // Openers are apps, or machines on machine→machine channels (a peerId is
  // the opener's connection id either way).
  const sockets = port.net.byConnectionId(peerId).filter((socket) => {
    const attachment = port.net.attachment(socket)
    return attachment?.helloDone === true && (attachment.kind === "app" || attachment.peerAware)
  })
  for (const socket of sockets) {
    if (port.net.send(socket, message)) return true
    port.retire(socket)
  }
  const session = port.resume.openerGraceSession(peerId, Date.now())
  return session === undefined ? false : bufferOrAbandon(port, session, message)
}
