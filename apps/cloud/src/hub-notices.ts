import {
  decodeRelayEnvelopes,
  encodeCloudFrame,
  parseHubToMachineRelayHeader,
  type HubToMachine
} from "@codevisor/api"

import { machinePresence, machineRow } from "./hub-schema.js"
import type { HubSockets } from "./hub-sockets.js"
import type { ResumeSessionRow, ResumeSessions } from "./resume-sessions.js"

/// The deferred death notices for a session nobody resumed — byte-for-byte
/// the announcements the hub used to make immediately on socket close, moved
/// behind the resume grace window (and extracted from user-hub.ts for size).

export interface HubNoticesPort {
  readonly net: HubSockets
  readonly resume: ResumeSessions
  readonly sql: SqlStorage
}

export const announceExpired = (port: HubNoticesPort, session: ResumeSessionRow): void => {
  if (session.kind === "machine") {
    const deviceId = session.device_id
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
      port.net.broadcastToApps({ t: "presence", machine: machinePresence(row, false) })
    }
    // Also broadcast the machine-offline error apps already understand
    // from failed relay attempts: their channels toward this machine are
    // dead, and a receive-only stream would otherwise never find out
    // (it sends nothing, so it can never provoke the reactive error).
    port.net.broadcastToApps({
      t: "error",
      code: "machine-offline",
      message: "machine disconnected from the relay",
      machineId: deviceId
    })
    return
  }
  // App gone (for good): let machines tear down that peer's channels.
  if (port.net.byConnectionId(session.connection_id).some((socket) => port.net.isRoutable(socket)))
    return
  const gone: HubToMachine = { t: "peer-gone", peerId: session.connection_id }
  for (const machineSocket of port.net.byTag("machine")) {
    if (port.net.isRoutable(machineSocket)) {
      port.net.send(machineSocket, encodeCloudFrame(gone))
    }
  }
}

/// Ends a grace session nobody resumed: its buffered frames are dropped, the
/// deferred death notices fire, and every app channel whose frames were in
/// the buffer is told it lost them.
export const abandonSession = (port: HubNoticesPort, session: ResumeSessionRow): void => {
  const dropped = port.resume.drainBuffers(session.connection_id)
  port.resume.delete(session.connection_id)
  announceExpired(port, session)
  if (session.kind === "machine") reportDroppedChannels(port, session.device_id, dropped)
}

/// Buffered app→machine frames never reached the machine. Without a notice
/// their channels wait forever for a reply: announceExpired is silent when
/// the machine is connected again under another session, and the app only
/// learns of a routed write failure through a channel-scoped error. Send
/// that same error (one per channel) to each opener still connected.
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
      // A dropped close needs no answer: its opener already let go.
      if (header === undefined || header.frame.t === "close") continue
      const channels = channelsByPeer.get(header.peerId) ?? new Set<string>()
      channels.add(header.frame.channelId)
      channelsByPeer.set(header.peerId, channels)
    }
  }
  for (const [peerId, channelIds] of channelsByPeer) {
    for (const socket of port.net.byConnectionId(peerId)) {
      if (port.net.attachment(socket)?.kind !== "app" || !port.net.isRoutable(socket)) continue
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

/// Buffers for a grace session, or — on overflow — abandons it: frames are
/// being dropped, so a later resume could not be seamless anyway. The
/// deferred death notices fire immediately, restoring pre-resume behavior.
export const bufferOrAbandon = (
  port: HubNoticesPort,
  session: ResumeSessionRow,
  message: Uint8Array
): boolean => {
  if (port.resume.buffer(session.connection_id, message)) return true
  // The caller reports `message` itself as undeliverable.
  abandonSession(port, session)
  return false
}
