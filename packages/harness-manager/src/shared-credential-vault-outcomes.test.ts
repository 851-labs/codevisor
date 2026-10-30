import { CREDENTIAL_RESERVATION_MS } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import {
  type CredentialCoordinator,
  OAuthRefreshRejected,
  OAuthRefreshUnavailable
} from "./shared-credential-types.js"
import { fixture, original, refreshed } from "./shared-credential-vault-test-support.js"
import {
  makeSharedCredentialVault,
  type SharedCredentialVaultConfig
} from "./shared-credential-vault.js"

describe("shared credential vault refresh outcomes", () => {
  it("releases the lease when the provider proves the refresh token was not spent", async () => {
    const f = fixture()
    const rotate = vi
      .fn<SharedCredentialVaultConfig["rotate"]>()
      .mockRejectedValueOnce(new OAuthRefreshUnavailable("HTTP 503"))
      .mockResolvedValueOnce(refreshed)
    const a = makeSharedCredentialVault({ ...f.config, rotate })
    const ref = await a.create(original)

    const failure = await a.token(ref).catch((cause: unknown) => cause)
    expect(failure).toBeInstanceOf(OAuthRefreshUnavailable)
    expect(f.records.get(ref.id)?.operation).toBeUndefined()
    const b = makeSharedCredentialVault({ ...f.config, rotate, coordinate: f.coordinate("b") })
    expect(await b.token(ref)).toEqual(refreshed)
    expect(rotate).toHaveBeenCalledTimes(2)
    expect(f.records.get(ref.id)?.generation).toBe(2)
  })

  it("keeps a rejected refresh distinguishable from other reauthentication", async () => {
    const f = fixture()
    const vault = makeSharedCredentialVault({
      ...f.config,
      rotate: async () => Promise.reject(new OAuthRefreshRejected(400, "invalid_grant"))
    })
    const failure = await vault.token(await vault.create(original)).catch((cause: unknown) => cause)
    expect(failure).toBeInstanceOf(OAuthRefreshRejected)
    expect(failure).toMatchObject({ reason: "reauthenticate", code: "invalid_grant" })
  })

  it("degrades to the old reservation timeout against a cloud that cannot release a started lease", async () => {
    const f = fixture()
    const oldCloud = (owner: string): CredentialCoordinator => {
      const current = f.coordinate(owner)
      return async (id, command) => {
        const record = f.records.get(id)
        if (command.action === "release" && record?.operation?.started === true) {
          return {
            status: "uncertain",
            credential: { generation: record.generation, sealed: record.sealed, revoked: false }
          }
        }
        return current(id, command)
      }
    }
    const a = makeSharedCredentialVault({
      ...f.config,
      coordinate: oldCloud("a"),
      rotate: async () => Promise.reject(new OAuthRefreshUnavailable("HTTP 503"))
    })
    const ref = await a.create(original)
    await expect(a.token(ref)).rejects.toBeInstanceOf(OAuthRefreshUnavailable)
    expect(f.records.get(ref.id)?.operation?.started).toBe(true)

    f.setTime(100_000 + CREDENTIAL_RESERVATION_MS)
    const b = makeSharedCredentialVault({ ...f.config, coordinate: oldCloud("b") })
    await expect(b.token(ref)).rejects.toMatchObject({ reason: "reauthenticate" })
    expect(f.config.rotate).not.toHaveBeenCalled()
  })
})
