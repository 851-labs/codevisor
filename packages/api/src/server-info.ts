import { Schema } from "effect"

export const ServerKind = Schema.Literals(["local", "remote"])
export type ServerKind = typeof ServerKind.Type

export const HealthResponse = Schema.Struct({
  ok: Schema.Boolean,
  version: Schema.String,
  database: Schema.Literals(["ready", "migrating", "failed"]),
  bootId: Schema.optional(Schema.String),
  processId: Schema.optional(Schema.Number),
  appOwned: Schema.optional(Schema.Boolean),
  buildNumber: Schema.optional(Schema.Number),
  sourceRevision: Schema.optional(Schema.String),
  serviceManaged: Schema.optional(Schema.Boolean),
  migration: Schema.optional(
    Schema.Struct({
      id: Schema.String,
      name: Schema.String,
      completed: Schema.Number,
      total: Schema.Number,
      error: Schema.optional(Schema.String)
    })
  )
})
export type HealthResponse = typeof HealthResponse.Type

export const ServerInfo = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  kind: ServerKind,
  version: Schema.String,
  platform: Schema.String,
  bindHost: Schema.String,
  features: Schema.optional(Schema.Array(Schema.String)),
  /// Stable machine identity persisted with the database; unlike `id` it
  /// survives --serverId defaults and renames. Optional for older servers.
  machineId: Schema.optional(Schema.String),
  arch: Schema.optional(Schema.String),
  hostname: Schema.optional(Schema.String)
})
export type ServerInfo = typeof ServerInfo.Type

/// Minimal tokenless manifest served at /v1/discovery so clients can find
/// Codevisor servers on a private network (e.g. tailnet peers) before pairing.
/// Deliberately excludes anything sensitive — pairing still requires a token.
export const DiscoveryInfo = Schema.Struct({
  serverId: Schema.String,
  machineId: Schema.String,
  name: Schema.String,
  kind: ServerKind,
  version: Schema.String,
  platform: Schema.String,
  hostname: Schema.String
})
export type DiscoveryInfo = typeof DiscoveryInfo.Type

/// A device on the machine's tailnet, read from `tailscale status --json`.
/// Served to paired clients (iOS has no way to enumerate tailnet peers
/// itself) so they can probe peers' /v1/discovery and offer them for adding.
export const TailnetPeer = Schema.Struct({
  hostName: Schema.String,
  /// MagicDNS name with the trailing dot stripped; preferred over the IP
  /// because it survives IP reassignment.
  dnsName: Schema.optional(Schema.String),
  ip: Schema.optional(Schema.String),
  os: Schema.optional(Schema.String),
  online: Schema.Boolean
})
export type TailnetPeer = typeof TailnetPeer.Type

export const TailnetPeersResponse = Schema.Struct({
  /// False when Tailscale isn't installed or isn't running on the machine —
  /// clients hide tailnet discovery entirely.
  available: Schema.Boolean,
  peers: Schema.Array(TailnetPeer)
})
export type TailnetPeersResponse = typeof TailnetPeersResponse.Type

/// An app-hosted server's report of the host app's unattended update
/// session (Sparkle running headless because a remote client asked this
/// machine to update). Lets that client fail fast with the real error
/// instead of timing out against a machine that silently gave up.
export const UpdateApplyState = Schema.Struct({
  state: Schema.Literals(["installing", "failed"]),
  message: Schema.optional(Schema.String),
  targetVersion: Schema.optional(Schema.String),
  at: Schema.String
})
export type UpdateApplyState = typeof UpdateApplyState.Type

export const UpdateInfo = Schema.Struct({
  currentVersion: Schema.String,
  latestVersion: Schema.String,
  updateAvailable: Schema.Boolean,
  channel: Schema.String,
  checkedAt: Schema.optional(Schema.String),
  migrationState: Schema.Literals(["idle", "running", "failed"]),
  /// CI build numbers matching the installed runtime's BUILD.json and the
  /// release manifest. Monotonic across every channel — unlike version
  /// strings, which diverge between the alpha manifest (full prerelease
  /// tag) and the runtime (base marketing version) — so clients compare
  /// these to decide whether an update landed. Absent on older servers and
  /// on releases predating build stamping.
  currentBuildNumber: Schema.optional(Schema.Number),
  latestBuildNumber: Schema.optional(Schema.Number),
  /// Present on app-hosted servers while the host app is installing (or
  /// after it failed to install) an update handed off by a remote client.
  lastApply: Schema.optional(UpdateApplyState)
})
export type UpdateInfo = typeof UpdateInfo.Type

export const PairingTokenResponse = Schema.Struct({
  token: Schema.String,
  createdAt: Schema.String
})
export type PairingTokenResponse = typeof PairingTokenResponse.Type
