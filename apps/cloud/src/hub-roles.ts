import {
  defaultRoleRanking,
  electRole,
  encodeCloudFrame,
  nextRoleCheck,
  rankedCandidates,
  releaseRole,
  renewRole,
  roleHolder,
  ROLE_LEASE_MS,
  type CloudRoleCandidate,
  type CloudRoleStatus,
  type HubToMachine,
  type MachineToHub,
  type RoleCandidate,
  type RoleHolderView,
  type RoleRanking,
  type RoleState
} from "@codevisor/api"

import { HubRoleStore, type RoleMember } from "./hub-role-store.js"
import type { SocketAttachment } from "./hub-schema.js"
import type { HubSockets } from "./hub-sockets.js"

export type RoleFrame = Extract<MachineToHub, { t: "role-members" | "role-renew" | "role-release" }>

export const isRoleFrame = (frame: MachineToHub): frame is RoleFrame =>
  frame.t === "role-members" || frame.t === "role-renew" || frame.t === "role-release"

export class HubRoles {
  readonly #store: HubRoleStore

  constructor(
    sql: SqlStorage,
    private readonly net: HubSockets,
    private readonly wakeAt: (deadline: number) => Promise<void>,
    private readonly rankingFor: (role: string) => RoleRanking = () => defaultRoleRanking
  ) {
    this.#store = new HubRoleStore(sql)
  }

  async handle(
    socket: WebSocket,
    attachment: SocketAttachment,
    frame: RoleFrame,
    now: number
  ): Promise<void> {
    if (!attachment.helloDone) return

    this.#apply(socket, attachment.deviceId!, frame, now)
    await this.#scheduleCheck(now)
  }

  gone(deviceId: string, now: number): void {
    if (!this.#store.markGone(deviceId, now)) return

    this.#settle(this.#store.rolesOf(deviceId), now)
    void this.#scheduleCheck(now)
  }

  forget(deviceId: string, now: number): void {
    const roles = this.#store.rolesOf(deviceId)
    this.#store.forget(deviceId)
    this.#settle(roles, now)
    void this.#scheduleCheck(now)
  }

  sweep(now: number): void {
    this.#settle(this.#store.roles(), now)
  }

  nextCheck(now: number): number | undefined {
    const checks = this.#store
      .roles()
      .map((role) =>
        nextRoleCheck(
          this.#store.state(role),
          this.#candidates(role, now),
          now,
          this.rankingFor(role)
        )
      )
      .filter((check): check is number => check !== undefined)
    return checks.length === 0 ? undefined : Math.min(...checks)
  }

  status(now: number): CloudRoleStatus[] {
    return this.#store.roles().map((role) => this.#roleStatus(role, now))
  }

  #apply(socket: WebSocket, deviceId: string, frame: RoleFrame, now: number): void {
    switch (frame.t) {
      case "role-members":
        return this.#join(socket, deviceId, frame, now)
      case "role-renew":
        return this.#renew(socket, deviceId, frame, now)
      case "role-release":
        return this.#release(deviceId, frame, now)
    }
  }

  async #scheduleCheck(now: number): Promise<void> {
    const next = this.nextCheck(now)
    if (next !== undefined) await this.wakeAt(next)
  }

  #join(
    socket: WebSocket,
    deviceId: string,
    frame: Extract<RoleFrame, { t: "role-members" }>,
    now: number
  ): void {
    const previous = this.#store.rolesOf(deviceId)
    this.#store.join(deviceId, frame, now)
    this.#settle([...previous, ...frame.candidate, ...frame.watch], now, { except: deviceId })

    const roles = this.#store.rolesOf(deviceId)
    this.#send(socket, { t: "role-holders", roles: roles.map((role) => this.#view(role, now)) })
  }

  #renew(
    socket: WebSocket,
    deviceId: string,
    frame: Extract<RoleFrame, { t: "role-renew" }>,
    now: number
  ): void {
    this.#settle([frame.role], now)

    const renewal = renewRole(this.#store.state(frame.role), deviceId, frame.version, now)
    if (renewal.held) this.#store.save(frame.role, renewal.state)
    this.#send(socket, {
      t: "role-lease",
      role: frame.role,
      version: frame.version,
      seq: frame.seq,
      held: renewal.held,
      leaseMs: ROLE_LEASE_MS
    })
  }

  #release(deviceId: string, frame: Extract<RoleFrame, { t: "role-release" }>, now: number): void {
    const state = this.#store.state(frame.role)
    const released = releaseRole(state, deviceId, frame.version)
    if (released === state) return

    this.#store.save(frame.role, released)
    this.#settle([frame.role], now, { always: true })
  }

  #settle(roles: ReadonlyArray<string>, now: number, announce: Announcement = {}): void {
    for (const role of new Set(roles)) this.#settleRole(role, now, announce)
  }

  #settleRole(role: string, now: number, announce: Announcement): void {
    const before = this.#store.state(role)
    const after = electRole(before, this.#candidates(role, now), now, this.rankingFor(role))
    if (after !== before) this.#store.save(role, after)
    if (startedHandoff(before, after)) this.#revoke(role, after)
    if (announce.always === true || holderChanged(before, after)) {
      this.#announce(role, now, announce.except)
    }
  }

  #revoke(role: string, state: RoleState): void {
    const frame: HubToMachine = {
      t: "role-lease",
      role,
      version: state.version,
      held: false,
      leaseMs: ROLE_LEASE_MS
    }
    for (const socket of this.#routable(state.lease!.holder)) this.#send(socket, frame)
  }

  #announce(role: string, now: number, except: string | undefined): void {
    const frame: HubToMachine = { t: "role-holders", roles: [this.#view(role, now)] }
    for (const member of this.#store.members(role, now)) {
      if (member.deviceId === except) continue
      for (const socket of this.#routable(member.deviceId)) this.#send(socket, frame)
    }
  }

  #view(role: string, now: number): RoleHolderView {
    const state = this.#store.state(role)
    const holder = roleHolder(state, now)
    return { role, version: state.version, ...(holder === undefined ? {} : { holder }) }
  }

  #candidates(role: string, now: number): RoleCandidate[] {
    return this.#store
      .members(role, now)
      .filter((member) => member.candidate && this.#online(member))
      .map(candidateOf)
  }

  #roleStatus(role: string, now: number): CloudRoleStatus {
    const state = this.#store.state(role)
    const ranked = rankedCandidates(this.#candidates(role, now), this.rankingFor(role))
    const rank = (deviceId: string) =>
      ranked.findIndex((candidate) => candidate.deviceId === deviceId)
    const candidates = this.#store
      .members(role, now)
      .filter((member) => member.candidate)
      .map((member) => this.#candidateStatus(member, rank(member.deviceId)))
    return { ...this.#view(role, now), ...leaseStatus(state, now), candidates }
  }

  #candidateStatus(member: RoleMember, rank: number): CloudRoleCandidate {
    return {
      deviceId: member.deviceId,
      ...(member.name === undefined ? {} : { name: member.name }),
      availability: member.availability,
      online: this.#online(member),
      ...(member.onlineSince === undefined
        ? {}
        : { onlineSince: new Date(member.onlineSince).toISOString() }),
      recentDrops: member.recentDrops,
      ...(rank < 0 ? {} : { rank: rank + 1 })
    }
  }

  #online(member: RoleMember): boolean {
    return member.onlineSince !== undefined && this.#routable(member.deviceId).length > 0
  }

  #routable(deviceId: string): WebSocket[] {
    return this.net.machine(deviceId).filter((socket) => this.net.isRoutable(socket))
  }

  #send(socket: WebSocket, frame: HubToMachine): void {
    this.net.send(socket, encodeCloudFrame(frame))
  }
}

interface Announcement {
  readonly always?: boolean
  readonly except?: string
}

const candidateOf = (member: RoleMember): RoleCandidate => ({
  deviceId: member.deviceId,
  availability: member.availability,
  onlineSince: member.onlineSince!,
  recentDrops: member.recentDrops
})

const startedHandoff = (before: RoleState, after: RoleState): boolean =>
  after.lease?.handingOff === true && before.lease?.handingOff !== true

const holderChanged = (before: RoleState, after: RoleState): boolean =>
  before.version !== after.version || before.lease?.holder !== after.lease?.holder

const leaseStatus = (
  state: RoleState,
  now: number
): Pick<CloudRoleStatus, "leaseExpiresAt" | "handingOff"> => {
  if (roleHolder(state, now) === undefined) return {}
  return {
    leaseExpiresAt: new Date(state.lease!.deadline).toISOString(),
    ...(state.lease!.handingOff ? { handingOff: true } : {})
  }
}
