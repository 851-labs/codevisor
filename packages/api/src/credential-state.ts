import type { CredentialCommand, CredentialCoordinationResult } from "./credential-coordination.js"

export interface CredentialLease {
  id: string
  owner: string
  deadline: number
  started: boolean
}

export interface CredentialRecord {
  generation: number
  sealed: string
  revoked: boolean
  operation?: CredentialLease
  committedOperation?: string
}

export interface CredentialCoordination {
  record: CredentialRecord | undefined
  result: CredentialCoordinationResult
}

export const CREDENTIAL_RESERVATION_MS = 30_000

export const coordinateCredential = (
  current: CredentialRecord | undefined,
  command: CredentialCommand,
  owner: string,
  now: number
): CredentialCoordination => {
  const record = seededRecord(clonedRecord(current), command)
  if (command.action === "revoke") return outcome(revokedRecord(record), "revoked")
  if (record === undefined) return outcome(record, "missing")
  if (record.revoked) return outcome(record, "revoked")

  switch (command.action) {
    case "read":
    case "seed":
      return outcome(record, "ready")
    case "acquire":
      return acquire(record, command, owner, now)
    case "start":
      return start(record, command, owner, now)
    case "commit":
      return commit(record, command, owner)
    case "release":
      return release(record, command, owner, now)
    default:
      return unrecognized(record, command, owner)
  }
}

type CredentialStatus = CredentialCoordinationResult["status"]
type AcquireCommand = Extract<CredentialCommand, { action: "acquire" }>
type CommitCommand = Extract<CredentialCommand, { action: "commit" }>

interface OperationCommand {
  readonly operationId: string
}

const acquire = (
  record: CredentialRecord,
  command: AcquireCommand,
  owner: string,
  now: number
): CredentialCoordination => {
  if (command.generation !== record.generation) return outcome(record, "ready")
  const held = heldLeaseStatus(record.operation, command, owner, now)
  if (held !== undefined) return outcome(record, held)

  record.operation = reservation(command, owner, now)
  return outcome(record, "acquired")
}

const start = (
  record: CredentialRecord,
  command: OperationCommand,
  owner: string,
  now: number
): CredentialCoordination => {
  const lease = callerLease(record, command, owner)
  if (lease === undefined) return outcome(record, "busy")
  if (cannotStart(lease, now)) return outcome(record, "uncertain")

  lease.started = true
  return outcome(record, "acquired")
}

const commit = (
  record: CredentialRecord,
  command: CommitCommand,
  owner: string
): CredentialCoordination => {
  if (alreadyCommitted(record, command, owner)) return outcome(record, "ready")
  const lease = callerLease(record, command, owner)
  if (lease === undefined) return outcome(record, "busy")
  if (!lease.started) return outcome(record, "uncertain")

  return outcome(committedRecord(record, command, owner), "ready")
}

const release = (
  record: CredentialRecord,
  command: OperationCommand,
  owner: string,
  now: number
): CredentialCoordination => {
  const lease = callerLease(record, command, owner)
  if (lease === undefined) return outcome(record, "busy")
  if (!canRelease(lease, now)) return outcome(record, "uncertain")

  delete record.operation
  return outcome(record, "ready")
}

const unrecognized = (
  record: CredentialRecord,
  command: OperationCommand,
  owner: string
): CredentialCoordination => {
  if (callerLease(record, command, owner) === undefined) return outcome(record, "busy")
  return outcome(record, "uncertain")
}

const outcome = (
  record: CredentialRecord | undefined,
  status: CredentialStatus
): CredentialCoordination => ({
  record,
  result: {
    status,
    ...(record === undefined ? {} : { credential: coordinatedCredential(record) })
  }
})

const coordinatedCredential = (record: CredentialRecord) => ({
  generation: record.generation,
  sealed: record.sealed,
  revoked: record.revoked
})

const clonedRecord = (current: CredentialRecord | undefined): CredentialRecord | undefined => {
  if (current === undefined) return undefined
  return structuredClone(current)
}

const seededRecord = (
  record: CredentialRecord | undefined,
  command: CredentialCommand
): CredentialRecord | undefined => {
  if (command.action !== "seed") return record
  if (record !== undefined) return record
  return { generation: 1, sealed: command.sealed, revoked: false }
}

const revokedRecord = (record: CredentialRecord | undefined): CredentialRecord => {
  if (record?.revoked !== true) {
    return { generation: (record?.generation ?? 0) + 1, sealed: "", revoked: true }
  }
  return record
}

const heldLeaseStatus = (
  lease: CredentialLease | undefined,
  command: OperationCommand,
  owner: string,
  now: number
): CredentialStatus | undefined => {
  if (lease === undefined) return undefined
  if (lease.started) return exchangeStatus(lease, now)
  if (beforeDeadline(lease, now)) return reservationStatus(lease, command, owner)
  return undefined
}

const exchangeStatus = (lease: CredentialLease, now: number): CredentialStatus =>
  pastDeadline(lease, now) ? "uncertain" : "busy"

const reservationStatus = (
  lease: CredentialLease,
  command: OperationCommand,
  owner: string
): CredentialStatus => (heldBy(lease, command, owner) ? "acquired" : "busy")

const reservation = (command: OperationCommand, owner: string, now: number): CredentialLease => ({
  id: command.operationId,
  owner,
  deadline: now + CREDENTIAL_RESERVATION_MS,
  started: false
})

const callerLease = (
  record: CredentialRecord,
  command: OperationCommand,
  owner: string
): CredentialLease | undefined => {
  const lease = record.operation
  if (lease === undefined) return undefined
  if (heldBy(lease, command, owner)) return lease
  return undefined
}

const committedRecord = (
  record: CredentialRecord,
  command: CommitCommand,
  owner: string
): CredentialRecord => ({
  generation: record.generation + 1,
  sealed: command.sealed,
  revoked: false,
  committedOperation: commitReceipt(owner, command)
})

const alreadyCommitted = (
  record: CredentialRecord,
  command: OperationCommand,
  owner: string
): boolean => record.committedOperation === commitReceipt(owner, command)

const commitReceipt = (owner: string, command: OperationCommand): string =>
  `${owner}:${command.operationId}`

const heldBy = (lease: CredentialLease, command: OperationCommand, owner: string): boolean =>
  lease.id === command.operationId && lease.owner === owner

const cannotStart = (lease: CredentialLease, now: number): boolean =>
  lease.started || pastDeadline(lease, now)

const canRelease = (lease: CredentialLease, now: number): boolean =>
  !lease.started || beforeDeadline(lease, now)

const pastDeadline = (lease: CredentialLease, now: number): boolean => lease.deadline <= now

const beforeDeadline = (lease: CredentialLease, now: number): boolean => lease.deadline > now
