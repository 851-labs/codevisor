import { expect, it } from "vitest"

import type { CredentialCommand } from "./credential-coordination.js"
import { coordinateCredential, type CredentialRecord } from "./credential-state.js"

const unleased: CredentialRecord = { generation: 3, sealed: "encrypted", revoked: false }
const record: CredentialRecord = {
  ...unleased,
  operation: { id: "operation-a", owner: "a", deadline: 10, started: false }
}
const undecoded = (text: string): CredentialCommand => JSON.parse(text)

it("answers an undecoded action like a lease call without changing the record", () => {
  const renew = undecoded('{ "action": "renew", "operationId": "operation-a" }')
  const holder = coordinateCredential(record, renew, "a", 1)
  expect(holder).toEqual({
    record,
    result: {
      status: "uncertain",
      credential: { generation: 3, sealed: "encrypted", revoked: false }
    }
  })
  expect(coordinateCredential(record, renew, "b", 1).result.status).toBe("busy")
  expect(coordinateCredential(unleased, renew, "a", 1).result.status).toBe("busy")
})

it("keeps a reservation when another machine or operation tries to release it", () => {
  const release = { action: "release", operationId: "operation-a" } as const
  expect(coordinateCredential(record, release, "b", 1)).toEqual({
    record,
    result: {
      status: "busy",
      credential: { generation: 3, sealed: "encrypted", revoked: false }
    }
  })
  expect(
    coordinateCredential(record, { ...release, operationId: "operation-b" }, "a", 1).result.status
  ).toBe("busy")
})
