import type { CredentialCommand, CredentialCoordinationResult } from "./credential-coordination.js"

export interface CredentialRecord {
  generation: number
  sealed: string
  revoked: boolean
  operation?: { id: string; owner: string; deadline: number; started: boolean }
  committedOperation?: string
}

/// A reservation can expire safely before provider I/O. Once provider I/O
/// starts, expiry is ambiguous: the provider may have rotated the token even
/// when its response was lost. Never let another machine replay that token.
export const CREDENTIAL_RESERVATION_MS = 30_000

export const coordinateCredential = (
  current: CredentialRecord | undefined,
  command: CredentialCommand,
  owner: string,
  now: number
): { record: CredentialRecord | undefined; result: CredentialCoordinationResult } => {
  let record = current === undefined ? undefined : structuredClone(current)
  const result = (status: CredentialCoordinationResult["status"]) => ({
    record,
    result: {
      status,
      ...(record === undefined
        ? {}
        : {
            credential: {
              generation: record.generation,
              sealed: record.sealed,
              revoked: record.revoked
            }
          })
    }
  })
  if (command.action === "seed" && record === undefined) {
    record = { generation: 1, sealed: command.sealed, revoked: false }
  }
  if (command.action === "revoke") {
    if (record?.revoked !== true)
      record = { generation: (record?.generation ?? 0) + 1, sealed: "", revoked: true }
    return result("revoked")
  }
  if (record === undefined) return result("missing")
  if (record.revoked) return result("revoked")
  if (command.action === "read" || command.action === "seed") return result("ready")
  if (command.action === "acquire") {
    if (command.generation !== record.generation) return result("ready")
    const pending = record.operation
    if (pending !== undefined) {
      if (pending.started) return result(now >= pending.deadline ? "uncertain" : "busy")
      if (pending.deadline > now) {
        return result(
          pending.id === command.operationId && pending.owner === owner ? "acquired" : "busy"
        )
      }
    }
    record.operation = {
      id: command.operationId,
      owner,
      deadline: now + CREDENTIAL_RESERVATION_MS,
      started: false
    }
    return result("acquired")
  }
  if (
    command.action === "commit" &&
    record.committedOperation === `${owner}:${command.operationId}`
  ) {
    return result("ready")
  }
  const pending = record.operation
  if (pending === undefined || pending.id !== command.operationId || pending.owner !== owner) {
    return result("busy")
  }
  if (command.action === "start") {
    // A lost start response must not authorize a second provider request.
    if (pending.started || pending.deadline <= now) return result("uncertain")
    pending.started = true
    return result("acquired")
  }
  if (command.action === "commit" && pending.started) {
    record = {
      generation: record.generation + 1,
      sealed: command.sealed,
      revoked: false,
      committedOperation: `${owner}:${command.operationId}`
    }
    return result("ready")
  }
  if (command.action === "release" && !pending.started) {
    delete record.operation
    return result("ready")
  }
  return result("uncertain")
}
