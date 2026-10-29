import { Schema } from "effect"

export const ROLES_FEATURE = "roles-v1"

export const RoleName = Schema.String.check(Schema.isPattern(/^[a-z0-9][a-z0-9-]{0,62}$/))

const RoleNames = Schema.Array(RoleName).check(Schema.isMaxLength(32))

const Counter = Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(0))

export const RoleAvailability = Schema.Literals(["always-on", "portable", "ephemeral"])
export type RoleAvailability = typeof RoleAvailability.Type

export const MachineRoleMembership = Schema.Struct({
  t: Schema.Literal("role-members"),
  availability: RoleAvailability,
  candidate: RoleNames,
  watch: RoleNames
})
export type MachineRoleMembership = typeof MachineRoleMembership.Type

export const MachineRoleRenew = Schema.Struct({
  t: Schema.Literal("role-renew"),
  role: RoleName,
  version: Counter,
  seq: Counter
})
export type MachineRoleRenew = typeof MachineRoleRenew.Type

export const MachineRoleRelease = Schema.Struct({
  t: Schema.Literal("role-release"),
  role: RoleName,
  version: Counter
})
export type MachineRoleRelease = typeof MachineRoleRelease.Type

export const RoleHolderView = Schema.Struct({
  role: Schema.String,
  version: Schema.Number,
  holder: Schema.optional(Schema.String)
})
export type RoleHolderView = typeof RoleHolderView.Type

export const HubRoleHolders = Schema.Struct({
  t: Schema.Literal("role-holders"),
  roles: Schema.Array(RoleHolderView)
})
export type HubRoleHolders = typeof HubRoleHolders.Type

export const HubRoleLease = Schema.Struct({
  t: Schema.Literal("role-lease"),
  role: Schema.String,
  version: Schema.Number,
  seq: Schema.optional(Schema.Number),
  held: Schema.Boolean,
  leaseMs: Schema.Number
})
export type HubRoleLease = typeof HubRoleLease.Type

export const CloudRoleCandidate = Schema.Struct({
  deviceId: Schema.String,
  name: Schema.optional(Schema.String),
  availability: RoleAvailability,
  online: Schema.Boolean,
  onlineSince: Schema.optional(Schema.String),
  recentDrops: Schema.Number,
  rank: Schema.optional(Schema.Number)
})
export type CloudRoleCandidate = typeof CloudRoleCandidate.Type

export const CloudRoleStatus = Schema.Struct({
  role: Schema.String,
  version: Schema.Number,
  holder: Schema.optional(Schema.String),
  leaseExpiresAt: Schema.optional(Schema.String),
  handingOff: Schema.optional(Schema.Boolean),
  candidates: Schema.Array(CloudRoleCandidate)
})
export type CloudRoleStatus = typeof CloudRoleStatus.Type

export const CloudRolesResponse = Schema.Struct({ roles: Schema.Array(CloudRoleStatus) })
export type CloudRolesResponse = typeof CloudRolesResponse.Type

export const MachineRoleView = Schema.Struct({
  role: Schema.String,
  version: Schema.Number,
  holder: Schema.optional(Schema.String),
  held: Schema.Boolean
})
export type MachineRoleView = typeof MachineRoleView.Type

export const MachineRolesResponse = Schema.Struct({
  machineId: Schema.optional(Schema.String),
  roles: Schema.Array(MachineRoleView),
  cloud: Schema.optional(Schema.Array(CloudRoleStatus)),
  cloudError: Schema.optional(Schema.String)
})
export type MachineRolesResponse = typeof MachineRolesResponse.Type
