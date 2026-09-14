// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import { isoTimestamp } from "@codevisor/api"
import { machineRow, machineRows, machinePresence } from "./hub-schema.js"
import { hasRoutableMachineSocket } from "./hub-delivery.js"
import type { HubNoticesPort } from "./hub-notices.js"

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
  hub.resume.deleteForMachineDevice(deviceId)
  for (const socket of hub.net.machine(deviceId)) {
    socket.close(closeCode, "machine disconnected from account")
  }
  hub.net.broadcastToApps({
    t: "presence",
    machine: machinePresence({ ...existing, last_seen_at: isoTimestamp() }, false)
  })
  return true
}
