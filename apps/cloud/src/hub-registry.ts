import { isoTimestamp, type CloudDeviceInfo } from "@codevisor/api"

import { hasRoutableMachineSocket } from "./hub-delivery.js"
import type { HubNoticesPort } from "./hub-notices.js"
import { machineRow, machineRows, machinePresence } from "./hub-schema.js"
import { isEndpointId } from "./hub-tunnel.js"

const MACHINE_ICON = /^[a-z0-9]+(?:\.[a-z0-9]+)*$/

export const isMachineIcon = (value: unknown): value is string =>
  typeof value === "string" && value.length <= 64 && MACHINE_ICON.test(value)

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
        peer_aware, tunnel_endpoint_id, reported_icon)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET
       name = excluded.name,
       os = excluded.os,
       reported_icon = excluded.reported_icon,
       app_version = excluded.app_version,
       public_key = excluded.public_key,
       last_seen_at = excluded.last_seen_at,
       active_generation = excluded.active_generation,
       server_id = excluded.server_id,
       peer_aware = excluded.peer_aware,
       tunnel_addr = CASE WHEN tunnel_endpoint_id IS excluded.tunnel_endpoint_id
         THEN tunnel_addr ELSE NULL END,
       tunnel_endpoint_id = excluded.tunnel_endpoint_id`,
    deviceId,
    device.name,
    device.os ?? null,
    device.appVersion ?? null,
    device.publicKey,
    isoTimestamp(),
    generation,
    device.serverId ?? null,
    peerAware ? 1 : 0,
    isEndpointId(device.tunnelEndpointId) ? device.tunnelEndpointId : null,
    isMachineIcon(device.icon) ? device.icon : null
  )
  return generation
}

export interface MachineUpdate {
  readonly name?: string
  readonly icon?: string
}

export const updateHubMachine = (
  hub: HubNoticesPort,
  deviceId: string,
  update: MachineUpdate
): boolean => {
  if (machineRow(hub.sql, deviceId) === undefined) return false
  if (update.name !== undefined) {
    hub.sql.exec("UPDATE machines SET display_name = ? WHERE device_id = ?", update.name, deviceId)
  }
  if (update.icon !== undefined) {
    hub.sql.exec("UPDATE machines SET icon = ? WHERE device_id = ?", update.icon, deviceId)
  }
  const row = machineRow(hub.sql, deviceId)
  if (row !== undefined) {
    hub.net.broadcastMachineNotice({
      t: "presence",
      machine: machinePresence(
        row,
        hasRoutableMachineSocket(hub.net, deviceId, row.active_generation) ||
          hub.resume.machineGraceSession(deviceId, Date.now()) !== undefined
      )
    })
  }
  return true
}

export const listHubMachines = (hub: HubNoticesPort) => {
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
  hub.sql.exec("DELETE FROM machine_origins WHERE device_id = ?", deviceId)
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

export const recordMachineOrigin = (
  sql: SqlStorage,
  deviceId: string,
  addedBy: { readonly deviceId: string; readonly name: string }
): void => {
  sql.exec(
    `INSERT INTO machine_origins (device_id, added_by_device_id, added_by_name)
     VALUES (?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET
       added_by_device_id = excluded.added_by_device_id,
       added_by_name = excluded.added_by_name`,
    deviceId,
    addedBy.deviceId,
    addedBy.name
  )
}
