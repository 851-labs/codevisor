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
  it("hands the unspent token back when the provider is unavailable", async () => {
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
  })

  it("retries a refresh whose answer was lost instead of signing out", async () => {
    const f = fixture()
    const rotate = vi
      .fn<SharedCredentialVaultConfig["rotate"]>()
      .mockRejectedValueOnce(new TypeError("fetch failed"))
      .mockResolvedValueOnce(refreshed)
    const a = makeSharedCredentialVault({ ...f.config, rotate })
    const ref = await a.create(original)

    await expect(a.token(ref)).rejects.toMatchObject({ reason: "offline" })
    f.setTime(100_000 + CREDENTIAL_RESERVATION_MS)
    const b = makeSharedCredentialVault({ ...f.config, rotate, coordinate: f.coordinate("b") })
    expect(await b.token(ref)).toEqual(refreshed)
    expect(rotate.mock.calls.map(([bundle]) => bundle.refreshToken)).toEqual([
      "old-refresh",
      "old-refresh"
    ])
  })

  it("recovers a refresh that lost the network along with the coordinator", async () => {
    const f = fixture()
    let online = true
    const flaky: CredentialCoordinator = async (id, command) => {
      if (!online) throw new TypeError("fetch failed")
      return f.coordinate("a")(id, command)
    }
    const rotate = vi
      .fn<SharedCredentialVaultConfig["rotate"]>()
      .mockImplementationOnce(async () => {
        online = false
        throw new TypeError("fetch failed")
      })
      .mockResolvedValueOnce(refreshed)
    const a = makeSharedCredentialVault({ ...f.config, coordinate: flaky, rotate })
    const ref = await a.create(original)

    await expect(a.token(ref)).rejects.toMatchObject({ reason: "offline" })
    expect(f.records.get(ref.id)?.operation?.started).toBe(true)

    f.setTime(100_000 + CREDENTIAL_RESERVATION_MS)
    const b = makeSharedCredentialVault({
      ...f.config,
      coordinate: f.coordinate("b"),
      receipt: fixture().config.receipt,
      rotate
    })
    await expect(b.token(ref)).rejects.toMatchObject({ reason: "reauthenticate" })
    expect(rotate).toHaveBeenCalledOnce()

    online = true
    expect(await a.token(ref)).toEqual(refreshed)
    expect(await b.token(ref)).toEqual(refreshed)
    expect(f.receipts.size).toBe(0)
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
})
