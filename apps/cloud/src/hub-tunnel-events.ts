import {
  type CloudDeviceInfo,
  type CloudTunnelInfo,
  encodeCloudFrame,
  isoTimestamp
} from "@codevisor/api"

import type { CloudEnv } from "./env.js"
import { machinePresence, machineRow, type SocketAttachment } from "./hub-schema.js"
import type { HubSockets } from "./hub-sockets.js"
import {
  isEndpointId,
  recordAppDevice,
  storeMachineTunnelAddr,
  tunnelRollout,
  tunnelScopedDevice,
  tunnelWelcome,
  vouchedDevices
} from "./hub-tunnel.js"

type TunnelWelcome = ReturnType<typeof tunnelWelcome>

export const onAppTunnelIdentity = (
  sql: SqlStorage,
  net: HubSockets,
  env: Pick<CloudEnv, "RELAY_MAP">,
  device: CloudDeviceInfo,
  now = isoTimestamp()
): TunnelWelcome => {
  const rollout = tunnelRollout(device)
  if (recordAppDevice(sql, tunnelScopedDevice(device, rollout), now)) {
    net.broadcastToTunnelMachines({ t: "peer-devices", devices: vouchedDevices(sql) })
  }
  return tunnelWelcome(env, rollout)
}

const machineTunnelScope = (
  env: Pick<CloudEnv, "RELAY_MAP">,
  device: CloudDeviceInfo
): { welcome: TunnelWelcome; device: CloudDeviceInfo; tunnelMachine: boolean } => {
  const rollout = tunnelRollout(device)
  const scoped = tunnelScopedDevice(device, rollout)
  return {
    welcome: tunnelWelcome(env, rollout),
    device: scoped,
    tunnelMachine: isEndpointId(scoped.tunnelEndpointId)
  }
}

export const sendPeerDevices = (sql: SqlStorage, net: HubSockets, socket: WebSocket): void => {
  if (net.attachment(socket)?.tunnel !== true) return
  net.send(socket, encodeCloudFrame({ t: "peer-devices", devices: vouchedDevices(sql) }))
}

export const onMachineTunnelAddr = (
  sql: SqlStorage,
  net: HubSockets,
  machine: Pick<SocketAttachment, "helloDone" | "deviceId">,
  tunnel: CloudTunnelInfo
): void => {
  if (!machine.helloDone) return
  const deviceId = machine.deviceId!
  if (!storeMachineTunnelAddr(sql, deviceId, tunnel)) return
  const row = machineRow(sql, deviceId)
  if (row !== undefined)
    net.broadcastMachineNotice({ t: "presence", machine: machinePresence(row, true) })
}

export const hubTunnel = {
  appHello: onAppTunnelIdentity,
  machineScope: machineTunnelScope,
  sendPeerDevices,
  addr: onMachineTunnelAddr
}
