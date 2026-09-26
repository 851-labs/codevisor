import { createRequire } from "node:module"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

/// Typed surface of the native tunnel addon (packages/net/crates/
/// codevisor-net-node). See docs/plans/codevisor-tunnel.md.

export const ALPN_CHANNELS = "codevisor/channels/1"
export const ALPN_MEDIA = "codevisor/media/1"

export type PathPolicy = "auto" | "relay-only" | "direct-only"

export interface RelayOptions {
  url: string
  /// UDP port of the relay's QUIC address discovery (default 7842).
  quicPort?: number
}

export interface EndpointOptions {
  /// 64-char hex Ed25519 secret key.
  secretKeyHex: string
  relays: RelayOptions[]
  /// Extra PEM trust anchors (local development's CA). Empty in production.
  trustAnchorsPem?: string[]
  /// UDP bind addresses, e.g. ["0.0.0.0:41641", "[::]:41641"]. Default: any.
  bindAddrs?: string[]
  pathPolicy?: PathPolicy
  alpns: string[]
}

export interface TunnelAddr {
  endpointId: string
  relayUrl?: string | null
  directAddrs: string[]
}

export interface TunnelPath {
  isRelay: boolean
  remote: string
  selected: boolean
  rttMs: number
}

export const MESSAGE_TEXT = 0
export const MESSAGE_BINARY = 1

export interface TunnelMessage {
  kind: number
  payload: Buffer
}

export interface TunnelMessageStream {
  send(kind: number, payload: Buffer): Promise<void>
  recv(): Promise<TunnelMessage | null>
  finish(): Promise<void>
}

export interface TunnelMediaFlow {
  localPort(): number
  close(): void
}

export interface TunnelConnection {
  remoteId(): string
  alpn(): string
  openMessageStream(): Promise<TunnelMessageStream>
  acceptMessageStream(): Promise<TunnelMessageStream>
  paths(): TunnelPath[]
  maxMediaPayload(): number | null
  /// Host side: bridge media flow `flowId` to a local UDP socket (`ip:port`,
  /// the host WebRTC's own candidate).
  forwardMedia(flowId: number, targetAddr: string): Promise<TunnelMediaFlow>
  /// Viewer side: a local UDP port (bound on all interfaces) bridged to the flow.
  bindMedia(flowId: number): Promise<TunnelMediaFlow>
  close(code: number, reason: string): void
  closed(): Promise<string>
}

export interface TunnelEndpoint {
  endpointId(): string
  addr(): TunnelAddr
  boundSockets(): string[]
  nextAddr(): Promise<TunnelAddr>
  online(timeoutMs: number): Promise<void>
  connect(addr: TunnelAddr, alpn: string): Promise<TunnelConnection>
  accept(): Promise<TunnelConnection | null>
  close(): Promise<void>
}

export interface NetModule {
  TunnelEndpoint: { bind(options: EndpointOptions): Promise<TunnelEndpoint> }
  generateSecretKeyHex(): string
  endpointIdForSecretKey(secretKeyHex: string): string
}

// Node's arch names (x64, arm64) are the directory names net-artifact.mjs uses.
const hostTarget = (): string => `${process.platform}-${process.arch}`

/// Where the addon lives: `CODEVISOR_NET_ADDON` (release runtimes point it at
/// the bundled copy), else `packages/net/native/<platform>-<arch>/` as
/// installed by `scripts/net-artifact.mjs ensure-node`.
export const defaultAddonPath = (environment: NodeJS.ProcessEnv = process.env): string =>
  environment.CODEVISOR_NET_ADDON ??
  join(dirname(fileURLToPath(import.meta.url)), "..", "native", hostTarget(), "codevisor_net.node")

const loaded = new Map<string, NetModule>()

/// Loads the native addon once per path. Throws with a build hint when it's
/// missing.
export const loadNet = (addonPath = defaultAddonPath()): NetModule => {
  const existing = loaded.get(addonPath)
  if (existing !== undefined) return existing
  const require = createRequire(import.meta.url)
  try {
    loaded.set(addonPath, require(addonPath) as NetModule)
  } catch (error) {
    throw new Error(
      `The codevisor-net addon is not available at ${addonPath}; run ` +
        `\`node scripts/net-artifact.mjs ensure-node\`. (${String(error)})`,
      { cause: error }
    )
  }
  return loaded.get(addonPath)!
}
