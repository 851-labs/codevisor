// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import { encodeCloudFrame, type HubToMachine } from "@codevisor/api"
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

/// Buffers for a grace session, or — on overflow — abandons it: frames are
/// being dropped, so a later resume could not be seamless anyway. The
/// deferred death notices fire immediately, restoring pre-resume behavior.
export const bufferOrAbandon = (
  port: HubNoticesPort,
  session: ResumeSessionRow,
  message: Uint8Array
): boolean => {
  if (port.resume.buffer(session.connection_id, message)) return true
  port.resume.delete(session.connection_id)
  announceExpired(port, session)
  return false
}
