import { describe, expect, it } from "vitest"

import {
  coordinateCredential,
  CREDENTIAL_RESERVATION_MS,
  type CredentialRecord
} from "./credential-state.js"

const initial: CredentialRecord = { generation: 1, sealed: "encrypted-original", revoked: false }
const acquire = { action: "acquire", generation: 1, operationId: "operation-a" } as const

describe("credential refresh coordination", () => {
  it("seeds a missing grant once and never replaces an existing grant with an older login", () => {
    expect(coordinateCredential(undefined, { action: "read" }, "a", 0)).toEqual({
      record: undefined,
      result: { status: "missing" }
    })
    const seeded = coordinateCredential(
      undefined,
      { action: "seed", sealed: initial.sealed },
      "a",
      0
    )
    expect(seeded).toEqual({ record: initial, result: { status: "ready", credential: initial } })
    expect(
      coordinateCredential(seeded.record, { action: "seed", sealed: "older" }, "b", 1)
    ).toEqual(seeded)
    expect(coordinateCredential(seeded.record, { action: "read" }, "b", 1)).toEqual(seeded)
  })

  it("keeps a reservation bound to its operation and machine until released or expired", () => {
    const held = coordinateCredential(initial, acquire, "a", 0)
    expect(initial.operation).toBeUndefined()
    expect(coordinateCredential(held.record, acquire, "a", 1)).toEqual(held)
    expect(coordinateCredential(held.record, acquire, "b", 1).result.status).toBe("busy")
    expect(
      coordinateCredential(held.record, { ...acquire, operationId: "different" }, "a", 1).result
        .status
    ).toBe("busy")
    expect(
      coordinateCredential(held.record, { action: "start", operationId: "different" }, "a", 1)
        .result.status
    ).toBe("busy")
    expect(
      coordinateCredential(
        held.record,
        { action: "commit", operationId: acquire.operationId, sealed: "too-early" },
        "a",
        1
      ).result.status
    ).toBe("uncertain")
    const released = coordinateCredential(
      held.record,
      { action: "release", operationId: acquire.operationId },
      "a",
      1
    )
    expect(released.record).toEqual(initial)
    expect(released.result.status).toBe("ready")
    expect(coordinateCredential(released.record, acquire, "b", 2).result.status).toBe("acquired")
    expect(
      coordinateCredential(
        held.record,
        { action: "start", operationId: acquire.operationId },
        "a",
        CREDENTIAL_RESERVATION_MS
      ).result.status
    ).toBe("uncertain")
  })

  it("returns busy while a provider exchange is active without extending its reservation", () => {
    const held = coordinateCredential(initial, acquire, "a", 0).record
    const started = coordinateCredential(
      held,
      { action: "start", operationId: acquire.operationId },
      "a",
      1
    )
    const contended = coordinateCredential(
      started.record,
      acquire,
      "b",
      CREDENTIAL_RESERVATION_MS - 1
    )
    expect(contended.result.status).toBe("busy")
    expect(contended.record).toEqual(started.record)
    expect(held?.operation?.started).toBe(false)
  })

  it("persists revocation even before a credential arrives and makes repeated revocation idempotent", () => {
    const revoked = coordinateCredential(undefined, { action: "revoke" }, "a", 0)
    expect(revoked).toEqual({
      record: { generation: 1, sealed: "", revoked: true },
      result: { status: "revoked", credential: { generation: 1, sealed: "", revoked: true } }
    })
    expect(coordinateCredential(revoked.record, { action: "revoke" }, "b", 1)).toEqual(revoked)
    expect(
      coordinateCredential(revoked.record, { action: "seed", sealed: "late" }, "b", 1)
    ).toEqual(revoked)
  })

  it("allows one refresh and returns the committed generation to the other machine", () => {
    const held = coordinateCredential(initial, acquire, "a", 0)
    expect(held.result.status).toBe("acquired")
    expect(
      coordinateCredential(held.record, { ...acquire, operationId: "operation-b" }, "b", 1).result
        .status
    ).toBe("busy")
    const started = coordinateCredential(
      held.record,
      { action: "start", operationId: acquire.operationId },
      "a",
      2
    )
    const committed = coordinateCredential(
      started.record,
      { action: "commit", operationId: acquire.operationId, sealed: "encrypted-rotated" },
      "a",
      3
    )
    expect(committed.result.credential).toEqual({
      generation: 2,
      sealed: "encrypted-rotated",
      revoked: false
    })
    const next = coordinateCredential(
      committed.record,
      { ...acquire, operationId: "operation-b" },
      "b",
      4
    )
    expect(next.result.status).toBe("ready")
    expect(next.record?.operation).toBeUndefined()
  })

  it("recovers an abandoned reservation but never replays an uncertain provider refresh", () => {
    const reserved = coordinateCredential(initial, acquire, "a", 0).record
    expect(
      coordinateCredential(
        reserved,
        { ...acquire, operationId: "b" },
        "b",
        CREDENTIAL_RESERVATION_MS
      ).result.status
    ).toBe("acquired")
    const started = coordinateCredential(
      reserved,
      { action: "start", operationId: acquire.operationId },
      "a",
      1
    ).record
    expect(
      coordinateCredential(
        started,
        { ...acquire, operationId: "b" },
        "b",
        CREDENTIAL_RESERVATION_MS
      ).result.status
    ).toBe("uncertain")
    expect(
      coordinateCredential(started, { action: "release", operationId: acquire.operationId }, "a", 2)
        .result.status
    ).toBe("uncertain")
    expect(
      coordinateCredential(started, { action: "start", operationId: acquire.operationId }, "a", 2)
        .result.status
    ).toBe("uncertain")
  })

  it("allows the owner to finish and retry a lost commit response", () => {
    const reserved = coordinateCredential(initial, acquire, "a", 0).record
    const started = coordinateCredential(
      reserved,
      { action: "start", operationId: acquire.operationId },
      "a",
      1
    ).record
    const command = { action: "commit", operationId: acquire.operationId, sealed: "new" } as const
    const finished = coordinateCredential(started, command, "a", CREDENTIAL_RESERVATION_MS + 1)
    expect(finished.result.status).toBe("ready")
    expect(
      coordinateCredential(finished.record, command, "a", CREDENTIAL_RESERVATION_MS + 2)
    ).toEqual(finished)
    expect(coordinateCredential(started, command, "b", 2).result.status).toBe("busy")
  })

  it("does not resurrect revoked credentials or accept stale writes", () => {
    const held = coordinateCredential(initial, acquire, "a", 0).record
    const revoked = coordinateCredential(held, { action: "revoke" }, "b", 1).record
    expect(
      coordinateCredential(revoked, { action: "seed", sealed: "old" }, "a", 2).result.status
    ).toBe("revoked")
    expect(
      coordinateCredential(
        revoked,
        { action: "commit", operationId: acquire.operationId, sealed: "old" },
        "a",
        3
      ).result.status
    ).toBe("revoked")
    expect(
      coordinateCredential(
        initial,
        { action: "commit", operationId: "other", sealed: "old" },
        "a",
        1
      ).result.status
    ).toBe("busy")
  })
})
