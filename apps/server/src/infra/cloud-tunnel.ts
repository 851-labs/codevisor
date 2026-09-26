import { readFile, writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"

import type { CloudRelayInfo, CloudTunnelInfo, CloudVouchedDevice } from "@codevisor/api"
import {
  admitTunnelHello,
  type ChannelHandler,
  DirectChannelHost,
  MachineTunnel,
  makePeerKeyPinStore,
  parsePeerKeyPins,
  type PeerKeyPinStore,
  serializePeerKeyPins,
  type TunnelMediaBridge,
  type TunnelMediaRequest,
  TunnelMediaRoutes
} from "@codevisor/cloud-client"
import { loadNet, type NetModule, type PathPolicy } from "@codevisor/net"

/// The machine's tunnel endpoint (docs/plans/codevisor-tunnel.md), wired to
/// the cloud bridge: the hub connection registers the endpoint and delivers
/// relay config + vouched app devices; the endpoint serves the same channel
/// handlers as the relay and the LAN pipe. Integration glue over the native
/// addon and the filesystem — the logic it composes is covered in
/// @codevisor/cloud-client (tunnel-host) and packages/net.
///
/// Configuration (production and development alike; only values differ):
/// - CODEVISOR_NET_DISABLED=1   — never start the tunnel on this machine
/// - CODEVISOR_NET_CA_FILE      — extra PEM trust anchors (local dev relays)
/// - CODEVISOR_NET_CA_PEM       — the same, inline (dev containers)
/// - CODEVISOR_NET_PATH_POLICY  — auto | relay-only | direct-only
/// - CODEVISOR_NET_BIND         — comma-separated UDP binds (fixed port)

export interface MachineTunnelBridge {
  readonly endpointId: string
  readonly onTunnelConfig: (config: { relays: readonly CloudRelayInfo[]; enabled: boolean }) => void
  readonly onPeerDevices: (devices: readonly CloudVouchedDevice[]) => void
  /// Screen-sharing media: bridge a viewer's flow to the host's candidate.
  readonly bridgeMedia: (
    request: TunnelMediaRequest,
    answer: string
  ) => Promise<TunnelMediaBridge | undefined>
  readonly stop: () => void
}

interface TunnelOptions {
  readonly credentialsPath: string
  readonly deviceId: string
  readonly secretKey: string
  readonly channelHandlers: Record<string, ChannelHandler>
  readonly peerKeyPins: PeerKeyPinStore
  readonly compressPayload: (bytes: Uint8Array) => Uint8Array | undefined
  readonly decompressPayload: (bytes: Uint8Array) => Uint8Array
  readonly sendAddr: (tunnel: CloudTunnelInfo) => void
  readonly env: Readonly<Record<string, string | undefined>>
  readonly log: (line: string) => void
}

/// The tunnel secret key lives beside cloud.json. It is separate from the
/// X25519 device key (Ed25519, iroh's identity) and survives restarts so the
/// endpoint id — which apps pin — stays stable.
export const tunnelKeyPath = (credentialsPath: string): string =>
  join(dirname(credentialsPath), "cloud-tunnel.json")

/// App endpoint pins (deviceId → endpoint id), the tunnel's companion to
/// cloud-peers.json. Deleting it is the manual recovery path, like pins.
export const tunnelPinsPath = (credentialsPath: string): string =>
  join(dirname(credentialsPath), "cloud-tunnel-peers.json")

const loadOrCreateSecretKey = async (net: NetModule, path: string): Promise<string> => {
  try {
    const parsed = JSON.parse(await readFile(path, "utf8")) as { secretKeyHex?: unknown }
    if (typeof parsed.secretKeyHex === "string" && /^[0-9a-f]{64}$/.test(parsed.secretKeyHex)) {
      return parsed.secretKeyHex
    }
  } catch {
    // Missing or unreadable: generate below.
  }
  const secretKeyHex = net.generateSecretKeyHex()
  await writeFile(path, JSON.stringify({ secretKeyHex }, null, 2), { mode: 0o600 })
  return secretKeyHex
}

const loadEndpointPins = async (options: TunnelOptions): Promise<PeerKeyPinStore> => {
  const path = tunnelPinsPath(options.credentialsPath)
  return makePeerKeyPinStore({
    initial: parsePeerKeyPins(await readFile(path, "utf8").catch(() => "")),
    persist: (peers) => {
      writeFile(path, serializePeerKeyPins(peers), { mode: 0o600 }).catch((cause: unknown) => {
        options.log(`Tunnel: failed to persist endpoint pins: ${String(cause)}`)
      })
    }
  })
}

const pathPolicy = (value: string | undefined): PathPolicy =>
  value === "relay-only" || value === "direct-only" ? value : "auto"

/// Prepares the tunnel for a bridge. Returns undefined — and the bridge runs
/// relay-only exactly as before — when disabled or the native addon is
/// unavailable on this platform.
export const prepareMachineTunnel = async (
  options: TunnelOptions
): Promise<MachineTunnelBridge | undefined> => {
  if (options.env.CODEVISOR_NET_DISABLED === "1") return undefined
  let net: NetModule
  try {
    net = loadNet()
  } catch (cause) {
    options.log(`Tunnel: unavailable (${cause instanceof Error ? cause.message : String(cause)})`)
    return undefined
  }
  const secretKeyHex = await loadOrCreateSecretKey(net, tunnelKeyPath(options.credentialsPath))
  const endpointPins = await loadEndpointPins(options)
  // A bad trust-anchor setting costs the tunnel its custom relays at most;
  // it must never take the cloud bridge down with it.
  const caFile = options.env.CODEVISOR_NET_CA_FILE
  const fileAnchor =
    caFile === undefined || caFile === ""
      ? undefined
      : await readFile(caFile, "utf8").catch((cause: unknown) => {
          options.log(`Tunnel: ignoring unreadable CODEVISOR_NET_CA_FILE: ${String(cause)}`)
          return undefined
        })
  const trustAnchorsPem = [
    ...(fileAnchor === undefined ? [] : [fileAnchor]),
    ...(options.env.CODEVISOR_NET_CA_PEM ? [options.env.CODEVISOR_NET_CA_PEM] : [])
  ]
  let vouched = new Map<string, CloudVouchedDevice>()
  // Endpoints whose channels hello this machine admitted; only they may open
  // media connections (the viewer always signals over channels first).
  const admittedEndpoints = new Set<string>()
  const admitHello = admitTunnelHello(
    { keys: options.peerKeyPins, endpoints: endpointPins },
    () => vouched
  )
  const media = new TunnelMediaRoutes({
    admit: (endpointId) => admittedEndpoints.has(endpointId),
    log: options.log
  })
  const host = new DirectChannelHost({
    deviceId: options.deviceId,
    secretKey: options.secretKey,
    channelHandlers: options.channelHandlers,
    peerKeyPins: options.peerKeyPins,
    compressPayload: options.compressPayload,
    decompressPayload: options.decompressPayload,
    admitHello: (device, peer) => {
      const admitted = admitHello(device, peer)
      if (admitted && peer.endpointId !== undefined) admittedEndpoints.add(peer.endpointId)
      return admitted
    },
    log: options.log
  })
  let lastAddr: CloudTunnelInfo | undefined
  const tunnel = new MachineTunnel({
    bind: (endpointOptions) => net.TunnelEndpoint.bind(endpointOptions),
    secretKeyHex,
    host,
    onAddr: (addr) => {
      lastAddr = addr
      options.sendAddr(addr)
    },
    onMedia: (connection) => media.offer(connection),
    trustAnchorsPem,
    bindAddrs: (options.env.CODEVISOR_NET_BIND ?? "")
      .split(",")
      .map((addr) => addr.trim())
      .filter((addr) => addr !== ""),
    pathPolicy: pathPolicy(options.env.CODEVISOR_NET_PATH_POLICY),
    log: options.log
  })
  return {
    endpointId: net.endpointIdForSecretKey(secretKeyHex),
    onTunnelConfig: (config) => {
      tunnel.configure(config).then(
        () => {
          // A reconnected hub may have missed changes while we were away.
          if (config.enabled && lastAddr !== undefined) options.sendAddr(lastAddr)
        },
        (cause: unknown) => options.log(`Tunnel: failed to start: ${String(cause)}`)
      )
    },
    onPeerDevices: (devices) => {
      vouched = new Map(devices.map((device) => [device.deviceId, device]))
    },
    bridgeMedia: (request, answer) => media.bridge(request, answer),
    stop: () => {
      void tunnel.stop()
    }
  }
}
