import { isoTimestamp, type CloudDeviceInfo } from "@codevisor/api"

import { hasRoutableMachineSocket } from "./hub-delivery.js"
import type { HubNoticesPort } from "./hub-notices.js"
import { machineRow, machineRows, machinePresence } from "./hub-schema.js"

/// Upserts a machine's registry row from its hello and installs the next
/// socket generation; returns that generation.
export const registerMachine = (
  sql: SqlStorage,
  deviceId: string,
  device: CloudDeviceInfo,
  peerAware: boolean
): number => {
  const generation = (machineRow(sql, deviceId)?.active_generation ?? 0) + 1
  sql.exec(
    `INSERT INTO machines
       (device_id, name, os, app_version, public_key, last_seen_at, active_generation, server_id,
        peer_aware)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET
       name = excluded.name,
       os = excluded.os,
       app_version = excluded.app_version,
       public_key = excluded.public_key,
       last_seen_at = excluded.last_seen_at,
       active_generation = excluded.active_generation,
       server_id = excluded.server_id,
       peer_aware = excluded.peer_aware`,
    deviceId,
    device.name,
    device.os ?? null,
    device.appVersion ?? null,
    device.publicKey,
    isoTimestamp(),
    generation,
    device.serverId ?? null,
    peerAware ? 1 : 0
  )
  return generation
}

export const listHubMachines = (hub: HubNoticesPort) => {
  // Machines in their resume grace window count as online: their
  // disconnect was never announced, and a resume makes it moot.
  const online = hub.resume.machineDeviceIdsInGrace(Date.now())
  const rows = machineRows(hub.sql)
  for (const row of rows) {
    if (hasRoutableMachineSocket(hub.net, row.device_id, row.active_generation)) {
      online.add(row.device_id)
    }
  }
  return rows.map((row) => machinePresence(row, online.has(row.device_id)))
}

export const removeHubMachine = (
  hub: HubNoticesPort,
  deviceId: string,
  closeCode: number
): boolean => {
  const existing = machineRow(hub.sql, deviceId)
  if (existing === undefined) return false
  hub.sql.exec("DELETE FROM machines WHERE device_id = ?", deviceId)
  for (const connectionId of hub.resume.deleteForMachineDevice(deviceId)) {
    hub.net.broadcastToPeerMachines({ t: "peer-gone", peerId: connectionId })
  }
  for (const socket of hub.net.machine(deviceId)) {
    socket.close(closeCode, "machine disconnected from account")
  }
  hub.net.broadcastMachineNotice({
    t: "presence",
    machine: machinePresence({ ...existing, last_seen_at: isoTimestamp() }, false)
  })
  return true
}
