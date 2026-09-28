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

/// CloudMachineConnection's options (split out of machine-connection.ts).

export const releaseChannelField = (
  channel: "stable" | "alpha" | undefined
): { releaseChannel?: "stable" | "alpha" } =>
  channel === undefined ? {} : { releaseChannel: channel }

export interface MachineConnectionOptions {
  credentials: MachineCredentials
  /// `serverId` is this machine's stable Codevisor server id, published in
  /// hub presence so peers list it under the id it reports in /v1/info.
  device: {
    name: string
    os?: string
    appVersion?: string
    serverId?: string
    /// This machine's update channel, read at every hello so a channel change
    /// applies on the next reconnect (the hub gates the tunnel by it).
    releaseChannel?: () => "stable" | "alpha" | undefined
  }
  socketFactory: SocketFactory
  /// Keyed by channelType (e.g. "terminal"). Unknown types are refused with
  /// close reason "unsupported".
  channelHandlers: Record<string, ChannelHandler>
  onStateChange?: (state: MachineConnectionState) => void
  onDisconnect?: (reason: MachineDisconnectReason) => void
  /// TOFU pin store for app-device keys. When provided, a channel open whose
  /// `peerPublicKey` conflicts with the pinned key for its `peerDeviceId` is
  /// refused ("rejected") — the hub is not trusted for key continuity. Keys
  /// pin only after a successful open (proof the opener holds the matching
  /// secret); opens without a device id (older hubs) proceed unpinned.
  peerKeyPins?: PeerKeyPinStore
  /// Fired on every refused open so integrators can log the substitution
  /// attempt with enough detail to investigate.
  onPeerKeyMismatch?: (info: { deviceId: string; pinned: string; presented: string }) => void
  /// Fired whenever the account's machine list (welcome + presence) changes.
  onMachinesChanged?: (machines: ReadonlyArray<CloudMachinePresence>) => void
  /// Coalesce outgoing relay envelopes for up to this long (see RelayOutbox).
  /// Default 0: every frame goes out immediately.
  relayCoalesceMs?: number
  /// Compresses an outgoing plaintext body on channels whose opener
  /// negotiated compressible framing; return undefined when not worthwhile.
  compressPayload?: (bytes: Uint8Array) => Uint8Array | undefined
  /// Inflates a DEFLATE-framed inbound body on negotiated channels. Absent =
  /// compressed inbound frames are refused (the app only compresses when the
  /// machine advertises support via this pair being wired up).
  decompressPayload?: (bytes: Uint8Array) => Uint8Array
  /// Observability: fired on every completed welcome so integrators can log
  /// resume outcomes (a resumed session replays its held frames silently).
  onWelcome?: (info: { resumed: boolean; replayedFrames: number }) => void
  /// This machine's tunnel endpoint id (hex). Registered with the hub on
  /// connect so our relays serve it and apps can dial it.
  tunnelEndpointId?: string
  /// Every welcome's relay map and rollout switch (docs/plans/
  /// codevisor-tunnel.md). Absent fields mean an older hub: no tunnel.
  onTunnelConfig?: (config: { relays: readonly CloudRelayInfo[]; enabled: boolean }) => void
  /// The app devices the hub vouches for (tunnel machines only).
  onPeerDevices?: (devices: readonly CloudVouchedDevice[]) => void
  scheduleReconnect?: (callback: () => void, delayMs: number) => void
  scheduleTimeout?: (callback: () => void, delayMs: number) => CancelTimeout
  random?: () => number
}
