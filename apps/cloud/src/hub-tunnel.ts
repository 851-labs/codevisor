import type {
  CloudDeviceInfo,
  CloudRelayInfo,
  CloudTunnelInfo,
  CloudTunnelRollout,
  CloudVouchedDevice
} from "@codevisor/api"

import type { CloudEnv } from "./env.js"

/// The hub's tunnel control plane (docs/plans/codevisor-tunnel.md). Devices
/// talk to each other directly over the tunnel; the hub only introduces them:
///
/// - machines report their endpoint id (hello) and address (`tunnel-addr`),
///   which apps receive in machine presence;
/// - apps report their endpoint id, and machines receive the account's app
///   devices as `peer-devices` so their tunnel listener can admit them.
///
/// Durable state lives in the hub's SQLite (see HUB_MIGRATIONS).

const ENDPOINT_ID = /^[0-9a-f]{64}$/

export const isEndpointId = (value: unknown): value is string =>
  typeof value === "string" && ENDPOINT_ID.test(value)

/// Instance relay map: `RELAY_MAP` (JSON array of CloudRelayInfo). Malformed
/// or absent → no relays (the tunnel still works on direct paths).
export const relayMap = (env: Pick<CloudEnv, "RELAY_MAP">): CloudRelayInfo[] => {
  if (env.RELAY_MAP === undefined || env.RELAY_MAP === "") return []
  try {
    const parsed: unknown = JSON.parse(env.RELAY_MAP)
    if (!Array.isArray(parsed)) return []
    return parsed.flatMap((entry: unknown): CloudRelayInfo[] => {
      if (typeof entry !== "object" || entry === null) return []
      const { url, quicPort } = entry as { url?: unknown; quicPort?: unknown }
      if (typeof url !== "string" || !url.startsWith("https://")) return []
      return [{ url, ...(typeof quicPort === "number" ? { quicPort } : {}) }]
    })
  } catch {
    return []
  }
}

/// Whether one connection gets the tunnel:
/// - machines always do (their servers keep serving the hub relay too, for
///   apps that still use it);
/// - tunnel-only apps always do (they have no other data path);
/// - apps that carry both paths (0.1.103) do on the Alpha update channel.
/// Devices that predate these fields keep the hub relay.
export const tunnelRollout = (
  device: Pick<CloudDeviceInfo, "kind" | "releaseChannel" | "tunnelOnly">
): CloudTunnelRollout =>
  device.kind === "machine" || device.tunnelOnly === true || device.releaseChannel === "alpha"
    ? "on"
    : "off"

/// The device as the hub records it: a device whose connection doesn't get
/// the tunnel has no tunnel identity, so peers never try to dial it (and
/// machines never receive a vouch for it).
export const tunnelScopedDevice = (
  device: CloudDeviceInfo,
  rollout: CloudTunnelRollout
): CloudDeviceInfo => {
  if (rollout === "on" || device.tunnelEndpointId === undefined) return device
  const { tunnelEndpointId: _hidden, ...rest } = device
  return rest
}

/// Welcome fields shared by apps and machines.
export const tunnelWelcome = (
  env: Pick<CloudEnv, "RELAY_MAP">,
  rollout: CloudTunnelRollout
): { relays: CloudRelayInfo[]; tunnel: CloudTunnelRollout } => ({
  relays: relayMap(env),
  tunnel: rollout
})

/// Presence `tunnel` block from the machine row's stored columns.
export const machineTunnel = (
  endpointId: string | null,
  storedAddr: string | null
): CloudTunnelInfo | undefined => {
  if (endpointId === null) return undefined
  let relayUrl: string | undefined
  let directAddrs: string[] = []
  if (storedAddr !== null) {
    try {
      const parsed = JSON.parse(storedAddr) as { relayUrl?: unknown; directAddrs?: unknown }
      if (typeof parsed.relayUrl === "string") relayUrl = parsed.relayUrl
      if (Array.isArray(parsed.directAddrs)) {
        directAddrs = parsed.directAddrs.filter((addr): addr is string => typeof addr === "string")
      }
    } catch {
      // A corrupt cache entry just means "no known address yet".
    }
  }
  return { endpointId, ...(relayUrl === undefined ? {} : { relayUrl }), directAddrs }
}

/// Stores a machine's reported address. Returns false when the report is for
/// a different endpoint than the machine registered (ignored).
export const storeMachineTunnelAddr = (
  sql: SqlStorage,
  deviceId: string,
  tunnel: CloudTunnelInfo
): boolean => {
  const stored = JSON.stringify({
    ...(tunnel.relayUrl === undefined ? {} : { relayUrl: tunnel.relayUrl }),
    directAddrs: tunnel.directAddrs.slice(0, 32)
  })
  return (
    sql.exec(
      "UPDATE machines SET tunnel_addr = ? WHERE device_id = ? AND tunnel_endpoint_id = ?",
      stored,
      deviceId,
      tunnel.endpointId
    ).rowsWritten > 0
  )
}

interface AppDeviceRow extends Record<string, SqlStorageValue> {
  device_id: string
  public_key: string
  endpoint_id: string
}

/// Records an app's tunnel identity from its hello. Returns true when the
/// vouched set changed (machines must be told).
export const recordAppDevice = (sql: SqlStorage, device: CloudDeviceInfo, now: string): boolean => {
  if (!isEndpointId(device.tunnelEndpointId)) return false
  const existing = sql
    .exec<AppDeviceRow>("SELECT * FROM app_devices WHERE device_id = ?", device.deviceId)
    .toArray()[0]
  sql.exec(
    `INSERT INTO app_devices (device_id, public_key, endpoint_id, last_seen_at)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET
       public_key = excluded.public_key,
       endpoint_id = excluded.endpoint_id,
       last_seen_at = excluded.last_seen_at`,
    device.deviceId,
    device.publicKey,
    device.tunnelEndpointId,
    now
  )
  return (
    existing?.public_key !== device.publicKey || existing.endpoint_id !== device.tunnelEndpointId
  )
}

export const vouchedDevices = (sql: SqlStorage): CloudVouchedDevice[] =>
  sql
    .exec<AppDeviceRow>("SELECT * FROM app_devices ORDER BY device_id")
    .toArray()
    .map((row) => ({
      deviceId: row.device_id,
      publicKey: row.public_key,
      endpointId: row.endpoint_id
    }))
