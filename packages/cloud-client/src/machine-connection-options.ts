import type { CloudMachinePresence, CloudRelayInfo, CloudVouchedDevice } from "@codevisor/api"

import type { ChannelHandler } from "./incoming-channel.js"
import type { MachineCredentials } from "./login.js"
import type {
  CancelTimeout,
  MachineConnectionState,
  MachineDisconnectReason,
  SocketFactory
} from "./machine-socket.js"
import type { PeerKeyPinStore } from "./peer-pins.js"

export const releaseChannelField = (
  channel: "stable" | "alpha" | undefined
): { releaseChannel?: "stable" | "alpha" } =>
  channel === undefined ? {} : { releaseChannel: channel }

export interface MachineConnectionOptions {
  credentials: MachineCredentials
  device: {
    name: string
    os?: string
    appVersion?: string
    serverId?: string
    releaseChannel?: () => "stable" | "alpha" | undefined
  }
  socketFactory: SocketFactory
  channelHandlers: Record<string, ChannelHandler>
  onStateChange?: (state: MachineConnectionState) => void
  onDisconnect?: (reason: MachineDisconnectReason) => void
  peerKeyPins?: PeerKeyPinStore
  onPeerKeyMismatch?: (info: { deviceId: string; pinned: string; presented: string }) => void
  onMachinesChanged?: (machines: ReadonlyArray<CloudMachinePresence>) => void
  relayCoalesceMs?: number
  compressPayload?: (bytes: Uint8Array) => Uint8Array | undefined
  decompressPayload?: (bytes: Uint8Array) => Uint8Array
  onWelcome?: (info: { resumed: boolean; replayedFrames: number }) => void
  tunnelEndpointId?: string
  onTunnelConfig?: (config: { relays: readonly CloudRelayInfo[]; enabled: boolean }) => void
  onPeerDevices?: (devices: readonly CloudVouchedDevice[]) => void
  scheduleReconnect?: (callback: () => void, delayMs: number) => void
  scheduleTimeout?: (callback: () => void, delayMs: number) => CancelTimeout
  random?: () => number
}
