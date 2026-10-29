import type { RoleAvailability } from "./cloud-role-protocol.js"

export const ROLE_LEASE_MS = 30_000
export const ROLE_RENEW_MS = 10_000
export const ROLE_STABLE_MS = 120_000

export interface RoleCandidate {
  readonly deviceId: string
  readonly availability: RoleAvailability
  readonly onlineSince: number
  readonly recentDrops: number
}

export interface RoleLease {
  readonly holder: string
  readonly deadline: number
  readonly handingOff: boolean
}

export interface RoleState {
  readonly version: number
  readonly lease?: RoleLease
}

export interface RoleRanking {
  readonly compare: (first: RoleCandidate, second: RoleCandidate) => number
  readonly preempts: (challenger: RoleCandidate, holder: RoleCandidate) => boolean
}

export interface RoleRenewal {
  readonly state: RoleState
  readonly held: boolean
}

export const VACANT_ROLE: RoleState = { version: 0 }

export const defaultRoleRanking: RoleRanking = {
  compare: (first, second) =>
    availabilityTier(first) - availabilityTier(second) ||
    first.recentDrops - second.recentDrops ||
    first.onlineSince - second.onlineSince ||
    first.deviceId.localeCompare(second.deviceId),
  preempts: (challenger, holder) => availabilityTier(challenger) < availabilityTier(holder)
}

export const electRole = (
  state: RoleState,
  candidates: ReadonlyArray<RoleCandidate>,
  now: number,
  ranking: RoleRanking = defaultRoleRanking
): RoleState => {
  const lease = liveLease(state, now)
  if (lease === undefined) return granted(state, successor(state, candidates, ranking), now)
  if (lease.handingOff) return state

  const challenger = preemptingChallenger(lease, candidates, now, ranking)
  if (challenger === undefined) return state

  return { ...state, lease: { ...lease, handingOff: true } }
}

export const renewRole = (
  state: RoleState,
  deviceId: string,
  version: number,
  now: number
): RoleRenewal => {
  const lease = liveLease(state, now)
  if (!renewable(state, lease, deviceId, version)) return { state, held: false }

  return { state: { ...state, lease: { ...lease, deadline: now + ROLE_LEASE_MS } }, held: true }
}

export const releaseRole = (state: RoleState, deviceId: string, version: number): RoleState => {
  if (!heldBy(state, deviceId, version)) return state
  return { version: state.version }
}

export const roleHolder = (state: RoleState, now: number): string | undefined =>
  liveLease(state, now)?.holder

export const nextRoleCheck = (
  state: RoleState,
  candidates: ReadonlyArray<RoleCandidate>,
  now: number,
  ranking: RoleRanking = defaultRoleRanking
): number | undefined => {
  const lease = liveLease(state, now)
  if (lease === undefined) return undefined
  if (lease.handingOff) return lease.deadline

  const settles = challengers(lease, candidates, ranking).map(stableAt)
  return Math.min(lease.deadline, ...settles)
}

export const rankedCandidates = (
  candidates: ReadonlyArray<RoleCandidate>,
  ranking: RoleRanking = defaultRoleRanking
): RoleCandidate[] => candidates.toSorted(ranking.compare)

const availabilityTiers: Record<RoleAvailability, number> = {
  "always-on": 0,
  portable: 1,
  ephemeral: 2
}

const availabilityTier = (candidate: RoleCandidate): number =>
  availabilityTiers[candidate.availability]

const liveLease = (state: RoleState, now: number): RoleLease | undefined => {
  if (state.lease === undefined || state.lease.deadline <= now) return undefined
  return state.lease
}

const successor = (
  state: RoleState,
  candidates: ReadonlyArray<RoleCandidate>,
  ranking: RoleRanking
): string | undefined => {
  const ranked = rankedCandidates(candidates, ranking)
  const other = ranked.find((candidate) => candidate.deviceId !== state.lease?.holder)
  return (other ?? ranked[0])?.deviceId
}

const granted = (state: RoleState, holder: string | undefined, now: number): RoleState => {
  if (holder === undefined) return { version: state.version }
  return {
    version: state.version + 1,
    lease: { holder, deadline: now + ROLE_LEASE_MS, handingOff: false }
  }
}

const preemptingChallenger = (
  lease: RoleLease,
  candidates: ReadonlyArray<RoleCandidate>,
  now: number,
  ranking: RoleRanking
): RoleCandidate | undefined =>
  challengers(lease, candidates, ranking).find((challenger) => stableAt(challenger) <= now)

const challengers = (
  lease: RoleLease,
  candidates: ReadonlyArray<RoleCandidate>,
  ranking: RoleRanking
): RoleCandidate[] => {
  const holder = candidates.find((candidate) => candidate.deviceId === lease.holder)
  if (holder === undefined) return []
  return candidates.filter((candidate) => ranking.preempts(candidate, holder))
}

const stableAt = (candidate: RoleCandidate): number => candidate.onlineSince + ROLE_STABLE_MS

const renewable = (
  state: RoleState,
  lease: RoleLease | undefined,
  deviceId: string,
  version: number
): lease is RoleLease =>
  lease !== undefined && !lease.handingOff && heldBy(state, deviceId, version)

const heldBy = (state: RoleState, deviceId: string, version: number): boolean =>
  state.lease?.holder === deviceId && state.version === version
