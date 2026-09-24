// Shared scaffolding for the shared-credential vault tests: token bundles and an in-memory
// coordinator, receipt store and clock.
import { coordinateCredential, type CredentialRecord } from "@codevisor/api"
import { vi } from "vitest"

import type { SharedTokenBundle, CredentialCoordinator } from "./shared-credential-types.js"

export const original: SharedTokenBundle = {
  harnessId: "codex",
  subject: "user",
  organizationId: "workspace",
  accessToken: "old-access",
  refreshToken: "old-refresh",
  expiresAt: 1,
  ownership: "managed"
}
export const refreshed = {
  ...original,
  accessToken: "new-access",
  refreshToken: "new-refresh",
  expiresAt: 10_000_000
}
export const gate = <T = void>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => {
    resolve = done
  })
  return { promise, resolve }
}
export const fixture = () => {
  const records = new Map<string, CredentialRecord>()
  let time = 100_000
  const coordinate =
    (owner: string): CredentialCoordinator =>
    async (id, command) => {
      const next = coordinateCredential(records.get(id), command, owner, time)
      if (next.record) records.set(id, next.record)
      return next.result
    }
  const receipts = new Map<string, { operationId: string; sealed: string }>()
  const receipt = {
    read: async (id: string) => receipts.get(id),
    write: async (id: string, value: { operationId: string; sealed: string }) => {
      receipts.set(id, value)
    },
    remove: async (id: string) => {
      receipts.delete(id)
    }
  }
  const config = {
    coordinate: coordinate("a"),
    rotate: vi.fn(async () => refreshed),
    receipt,
    now: () => time,
    elapsed: () => time
  }
  return {
    config,
    coordinate,
    records,
    receipts,
    setTime: (value: number) => {
      time = value
    }
  }
}
