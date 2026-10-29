import type { RoleAvailability, RoleState } from "@codevisor/api"

export const ROLE_DROP_WINDOW_MS = 24 * 60 * 60 * 1000

export interface RoleMember {
  readonly deviceId: string
  readonly name: string | undefined
  readonly candidate: boolean
  readonly availability: RoleAvailability
  readonly onlineSince: number | undefined
  readonly recentDrops: number
}

export interface RoleMembership {
  readonly availability: RoleAvailability
  readonly candidate: ReadonlyArray<string>
  readonly watch: ReadonlyArray<string>
}

export class HubRoleStore {
  constructor(private readonly sql: SqlStorage) {}

  join(deviceId: string, membership: RoleMembership, now: number): void {
    this.sql.exec(
      roleMachineSql.join,
      deviceId,
      availabilityFor(this.sql, deviceId, membership),
      now
    )
    this.sql.exec(roleMemberSql.deleteDevice, deviceId)
    for (const role of membership.watch) this.sql.exec(roleMemberSql.insert, role, deviceId, 0)
    for (const role of membership.candidate) this.sql.exec(roleMemberSql.insert, role, deviceId, 1)
  }

  markGone(deviceId: string, now: number): boolean {
    const marked = this.sql.exec(roleMachineSql.markGone, now, now - ROLE_DROP_WINDOW_MS, deviceId)
    return marked.rowsWritten > 0
  }

  forget(deviceId: string): void {
    this.sql.exec(roleMemberSql.deleteDevice, deviceId)
    this.sql.exec(roleMachineSql.delete, deviceId)
  }

  rolesOf(deviceId: string): string[] {
    return this.sql.exec<RoleRow>(roleMemberSql.rolesOf, deviceId).toArray().map(roleOf)
  }

  roles(): string[] {
    return this.sql.exec<RoleRow>(roleSql.all).toArray().map(roleOf)
  }

  members(role: string, now: number): RoleMember[] {
    return this.sql
      .exec<MemberRow>(roleMemberSql.members, role)
      .toArray()
      .map((row) => member(row, now))
  }

  state(role: string): RoleState {
    const row = this.sql.exec<LeaseRow>(roleLeaseSql.byRole, role).toArray()[0]
    return row === undefined ? { version: 0 } : leaseState(row)
  }

  save(role: string, state: RoleState): void {
    const lease = state.lease
    this.sql.exec(
      roleLeaseSql.upsert,
      role,
      state.version,
      lease?.holder ?? null,
      lease?.deadline ?? null,
      lease?.handingOff === true ? 1 : 0
    )
  }
}

const availabilityFor = (
  sql: SqlStorage,
  deviceId: string,
  membership: RoleMembership
): RoleAvailability => {
  const origin = sql.exec<OriginRow>(roleMachineSql.ephemeralOrigin, deviceId).toArray()[0]
  return origin === undefined ? membership.availability : "ephemeral"
}

const member = (row: MemberRow, now: number): RoleMember => ({
  deviceId: row.device_id,
  name: row.name ?? undefined,
  candidate: row.candidate === 1,
  availability: availabilityOf(row.availability),
  onlineSince: row.online_since ?? undefined,
  recentDrops: row.drops_since > now - ROLE_DROP_WINDOW_MS ? row.drops : 0
})

const availabilityOf = (value: string): RoleAvailability => {
  if (value === "portable" || value === "ephemeral") return value
  return "always-on"
}

const leaseState = (row: LeaseRow): RoleState => {
  if (row.holder === null || row.deadline === null) return { version: row.version }
  return {
    version: row.version,
    lease: { holder: row.holder, deadline: row.deadline, handingOff: row.handing_off === 1 }
  }
}

const roleOf = (row: RoleRow): string => row.role

interface RoleRow extends Record<string, SqlStorageValue> {
  role: string
}

interface OriginRow extends Record<string, SqlStorageValue> {
  ephemeral_provider: string
}

interface MemberRow extends Record<string, SqlStorageValue> {
  device_id: string
  name: string | null
  candidate: number
  availability: string
  online_since: number | null
  drops: number
  drops_since: number
}

interface LeaseRow extends Record<string, SqlStorageValue> {
  version: number
  holder: string | null
  deadline: number | null
  handing_off: number
}

const roleMachineSql = {
  join: `INSERT INTO role_machines (device_id, availability, online_since) VALUES (?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET availability = excluded.availability,
       online_since = COALESCE(role_machines.online_since, excluded.online_since)`,
  markGone: `UPDATE role_machines SET online_since = NULL,
       drops = CASE WHEN drops_since > ?2 THEN drops + 1 ELSE 1 END,
       drops_since = CASE WHEN drops_since > ?2 THEN drops_since ELSE ?1 END
     WHERE device_id = ?3 AND online_since IS NOT NULL`,
  delete: "DELETE FROM role_machines WHERE device_id = ?",
  ephemeralOrigin: `SELECT ephemeral_provider FROM machine_origins
     WHERE device_id = ? AND ephemeral_provider IS NOT NULL`
}

const roleMemberSql = {
  insert: `INSERT INTO role_members (role, device_id, candidate) VALUES (?, ?, ?)
     ON CONFLICT(role, device_id) DO UPDATE SET candidate = MAX(candidate, excluded.candidate)`,
  deleteDevice: "DELETE FROM role_members WHERE device_id = ?",
  rolesOf: "SELECT role FROM role_members WHERE device_id = ? ORDER BY role",
  members: `SELECT role_members.device_id, role_members.candidate,
       COALESCE(machines.display_name, machines.name) AS name, role_machines.availability,
       role_machines.online_since, role_machines.drops, role_machines.drops_since
     FROM role_members JOIN role_machines USING (device_id)
     LEFT JOIN machines USING (device_id)
     WHERE role_members.role = ? ORDER BY role_members.device_id`
}

const roleLeaseSql = {
  byRole: "SELECT version, holder, deadline, handing_off FROM role_leases WHERE role = ?",
  upsert: `INSERT INTO role_leases (role, version, holder, deadline, handing_off)
     VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(role) DO UPDATE SET version = excluded.version, holder = excluded.holder,
       deadline = excluded.deadline, handing_off = excluded.handing_off`
}

const roleSql = {
  all: `SELECT role FROM role_members UNION SELECT role FROM role_leases
     WHERE holder IS NOT NULL ORDER BY role`
}
