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

/// The hub's reactions to tunnel control frames, kept out of user-hub.ts.

/// An app said hello: decide whether its connection gets the tunnel and, if
/// so, remember its tunnel identity and tell every machine when the vouched
/// set changed. Returns the welcome's tunnel fields.
export const onAppTunnelIdentity = (
  sql: SqlStorage,
  net: HubSockets,
  env: Pick<CloudEnv, "RELAY_MAP" | "TUNNEL_ROLLOUT">,
  device: CloudDeviceInfo,
  now = isoTimestamp()
): TunnelWelcome => {
  const rollout = tunnelRollout(env, device)
  if (recordAppDevice(sql, tunnelScopedDevice(device, rollout), now)) {
    net.broadcastToTunnelMachines({ t: "peer-devices", devices: vouchedDevices(sql) })
  }
  return tunnelWelcome(env, rollout)
}

/// A machine said hello: the welcome's tunnel fields, the device to record
/// (without a tunnel identity when its connection doesn't get the tunnel, so
/// apps never try to dial it), and whether it is a tunnel machine (receives
/// `peer-devices`).
export const machineTunnelScope = (
  env: Pick<CloudEnv, "RELAY_MAP" | "TUNNEL_ROLLOUT">,
  device: CloudDeviceInfo
): { welcome: TunnelWelcome; device: CloudDeviceInfo; tunnelMachine: boolean } => {
  const rollout = tunnelRollout(env, device)
  const scoped = tunnelScopedDevice(device, rollout)
  return {
    welcome: tunnelWelcome(env, rollout),
    device: scoped,
    tunnelMachine: isEndpointId(scoped.tunnelEndpointId)
  }
}

/// A tunnel machine finished hello: hand it the vouched app devices.
export const sendPeerDevices = (sql: SqlStorage, net: HubSockets, socket: WebSocket): void => {
  if (net.attachment(socket)?.tunnel !== true) return
  net.send(socket, encodeCloudFrame({ t: "peer-devices", devices: vouchedDevices(sql) }))
}

/// A machine reported a new tunnel address: store it and republish presence.
/// Reports before hello are ignored.
export const onMachineTunnelAddr = (
  sql: SqlStorage,
  net: HubSockets,
  machine: Pick<SocketAttachment, "helloDone" | "deviceId">,
  tunnel: CloudTunnelInfo
): void => {
  if (machine.helloDone !== true) return
  const deviceId = machine.deviceId!
  if (!storeMachineTunnelAddr(sql, deviceId, tunnel)) return
  const row = machineRow(sql, deviceId)
  if (row !== undefined)
    net.broadcastMachineNotice({ t: "presence", machine: machinePresence(row, true) })
}

/// The handlers user-hub.ts calls, under one import.
export const hubTunnel = {
  appHello: onAppTunnelIdentity,
  machineScope: machineTunnelScope,
  sendPeerDevices,
  addr: onMachineTunnelAddr
}
