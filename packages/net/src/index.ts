import { createRequire } from "node:module"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

export const ALPN_CHANNELS = "codevisor/channels/1"
export const ALPN_MEDIA = "codevisor/media/1"

export type PathPolicy = "auto" | "relay-only" | "direct-only"

export interface RelayOptions {
  url: string
  quicPort?: number
}

export interface EndpointOptions {
  secretKeyHex: string
  relays: RelayOptions[]
  trustAnchorsPem?: string[]
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
  forwardMedia(flowId: number, targetAddr: string): Promise<TunnelMediaFlow>
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

const hostTarget = (): string => `${process.platform}-${process.arch}`

export const defaultAddonPath = (environment: NodeJS.ProcessEnv = process.env): string =>
  environment.CODEVISOR_NET_ADDON ??
  join(dirname(fileURLToPath(import.meta.url)), "..", "native", hostTarget(), "codevisor_net.node")

const loaded = new Map<string, NetModule>()

export const loadNet = (addonPath = defaultAddonPath()): NetModule => {
  const existing = loaded.get(addonPath)
  if (existing !== undefined) return existing
  const require = createRequire(import.meta.url)
  try {
    // oxlint-disable-next-line typescript/no-unsafe-type-assertion
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
