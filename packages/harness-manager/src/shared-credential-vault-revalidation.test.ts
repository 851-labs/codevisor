import { describe, expect, it, vi } from "vitest"

import type { CredentialCoordinator } from "./shared-credential-types.js"
import { fixture, gate, refreshed } from "./shared-credential-vault-test-support.js"
import { makeSharedCredentialVault } from "./shared-credential-vault.js"

describe("revalidating a held credential", () => {
  it("serves a confirmed credential locally until invalidated or the window lapses", async () => {
    const f = fixture()
    const coordinate = vi.fn(f.config.coordinate)
    const vault = makeSharedCredentialVault({ ...f.config, coordinate })
    const ref = await vault.create(refreshed)
    coordinate.mockClear()
    for (const token of await Promise.all(Array.from({ length: 50 }, () => vault.token(ref))))
      expect(token).toEqual(refreshed)
    expect(coordinate).not.toHaveBeenCalled()
    vault.invalidate()
    expect(await vault.token(ref)).toEqual(refreshed)
    expect(coordinate).toHaveBeenCalledTimes(1)
    await f.coordinate("b")(ref.id, { action: "revoke" })
    expect(await vault.token(ref)).toEqual(refreshed)
    f.setTime(100_000 + 5 * 60_000)
    expect(await vault.token(ref)).toEqual(refreshed)
    await vi.waitFor(() => expect(coordinate).toHaveBeenCalledTimes(2))
    expect(coordinate).toHaveBeenLastCalledWith(ref.id, { action: "read" })
    await expect(vault.token(ref)).rejects.toThrow("signed out")
    expect(f.config.rotate).not.toHaveBeenCalled()
  })

  it("serves a still-valid token past the window while one background read revalidates it", async () => {
    const f = fixture(),
      held = gate(),
      entered = gate()
    const coordinate = vi.fn<CredentialCoordinator>(async (id, command) => {
      if (command.action === "read") {
        entered.resolve()
        await held.promise
      }
      return f.config.coordinate(id, command)
    })
    const vault = makeSharedCredentialVault({ ...f.config, coordinate })
    const ref = await vault.create(refreshed)
    coordinate.mockClear()
    f.setTime(100_000 + 5 * 60_000)
    expect(await vault.token(ref)).toEqual(refreshed)
    await entered.promise
    expect(await Promise.all([vault.token(ref), vault.token(ref)])).toEqual([refreshed, refreshed])
    const rejected = vault.token(ref, refreshed.accessToken)
    held.resolve()
    expect((await rejected).accessToken).toBe(refreshed.accessToken)
    expect(coordinate.mock.calls.filter(([, command]) => command.action === "read")).toHaveLength(2)
    coordinate.mockClear()
    expect(await vault.token(ref)).toEqual(refreshed)
    expect(coordinate).not.toHaveBeenCalled()
  })

  it("keeps serving a valid token when background revalidation hits an unreadable record", async () => {
    const f = fixture()
    let corrupt = false
    const coordinate = vi.fn<CredentialCoordinator>(async (id, command) => {
      const result = await f.config.coordinate(id, command)
      if (!corrupt || result.status !== "ready") return result
      return { ...result, credential: { ...result.credential!, sealed: "corrupt" } }
    })
    const vault = makeSharedCredentialVault({ ...f.config, coordinate })
    const ref = await vault.create(refreshed)
    corrupt = true
    f.setTime(100_000 + 5 * 60_000)
    expect(await vault.token(ref)).toEqual(refreshed)
    await vi.waitFor(() => expect(coordinate).toHaveBeenCalledTimes(2))
    await Promise.resolve()
    corrupt = false
    expect(await vault.token(ref)).toEqual(refreshed)
  })

  it("still waits for revalidation for tokens whose callers cannot retry a rejected one", async () => {
    const f = fixture(),
      held = gate()
    let hold = false
    const vault = makeSharedCredentialVault({
      ...f.config,
      coordinate: async (id, command) => {
        if (hold && command.action === "read") await held.promise
        return f.config.coordinate(id, command)
      }
    })
    const piToken = { ...refreshed, harnessId: "pi" as const }
    const ref = await vault.create(piToken)
    hold = true
    f.setTime(100_000 + 5 * 60_000)
    let settled = false
    const token = vault.token(ref).finally(() => {
      settled = true
    })
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(settled).toBe(false)
    held.resolve()
    expect(await token).toEqual(piToken)
  })
})
