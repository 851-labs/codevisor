import {
  decodeRelayEnvelopes,
  encodeCloudFrame,
  parseHubToMachineRelayHeader,
  type HubToMachine
} from "@codevisor/api"

import { machinePresence, machineRow } from "./hub-schema.js"
import type { HubSockets } from "./hub-sockets.js"
import type { ResumeSessionRow, ResumeSessions } from "./resume-sessions.js"

export interface HubNoticesPort {
  readonly net: HubSockets
  readonly resume: ResumeSessions
  readonly sql: SqlStorage
}

export const announceExpired = (port: HubNoticesPort, session: ResumeSessionRow): void => {
  if (session.kind === "machine") {
    const deviceId = session.device_id
    port.net.broadcastToPeerMachines({ t: "peer-gone", peerId: session.connection_id })
    const row = machineRow(port.sql, deviceId)
    const stillConnected = port.net.machine(deviceId).some((candidate) => {
      const attachment = port.net.attachment(candidate)
      return (
        row !== undefined &&
        port.net.isRoutable(candidate) &&
        (attachment?.machineGeneration ?? 0) === row.active_generation
      )
    })
    if (stillConnected) return
    if (row !== undefined) {
      port.net.broadcastMachineNotice({ t: "presence", machine: machinePresence(row, false) })
    }
    port.net.broadcastMachineNotice({
      t: "error",
      code: "machine-offline",
      message: "machine disconnected from the relay",
      machineId: deviceId
    })
    return
  }
  if (port.net.byConnectionId(session.connection_id).some((socket) => port.net.isRoutable(socket)))
    return
  const gone: HubToMachine = { t: "peer-gone", peerId: session.connection_id }
  for (const machineSocket of port.net.byTag("machine")) {
    if (port.net.isRoutable(machineSocket)) {
      port.net.send(machineSocket, encodeCloudFrame(gone))
    }
  }
}

export const abandonSession = (port: HubNoticesPort, session: ResumeSessionRow): void => {
  const dropped = port.resume.drainBuffers(session.connection_id)
  port.resume.delete(session.connection_id)
  announceExpired(port, session)
  if (session.kind === "machine") reportDroppedChannels(port, session.device_id, dropped)
}

const reportDroppedChannels = (
  port: HubNoticesPort,
  machineId: string,
  messages: Uint8Array[]
): void => {
  const channelsByPeer = new Map<string, Set<string>>()
  for (const message of messages) {
    let envelopes
    try {
      envelopes = decodeRelayEnvelopes(message)
    } catch {
      continue
    }
    for (const envelope of envelopes) {
      const header = parseHubToMachineRelayHeader(envelope.header)
      if (header === undefined || header.frame.t === "close") continue
      const channels = channelsByPeer.get(header.peerId) ?? new Set<string>()
      channels.add(header.frame.channelId)
      channelsByPeer.set(header.peerId, channels)
    }
  }
  for (const [peerId, channelIds] of channelsByPeer) {
    for (const socket of port.net.byConnectionId(peerId)) {
      if (!port.net.isRoutable(socket)) continue
      for (const channelId of channelIds) {
        port.net.send(
          socket,
          encodeCloudFrame({
            t: "error",
            code: "machine-offline",
            message: "machine relay delivery failed",
            machineId,
            channelId
          })
        )
      }
    }
  }
}

export const bufferOrAbandon = (
  port: HubNoticesPort,
  session: ResumeSessionRow,
  message: Uint8Array
): boolean => {
  if (port.resume.buffer(session.connection_id, message)) return true
  abandonSession(port, session)
  return false
}
