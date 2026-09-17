import { coordinateCredential, type CredentialRecord } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import type { SharedTokenBundle, CredentialCoordinator } from "./shared-credential-types.js"
import {
  makeSharedCredentialVault,
  openSharedCredential,
  sealSharedCredential
} from "./shared-credential-vault.js"

const original: SharedTokenBundle = {
  harnessId: "codex",
  subject: "user",
  organizationId: "workspace",
  accessToken: "old-access",
  refreshToken: "old-refresh",
  expiresAt: 1,
  ownership: "managed"
}
const refreshed = {
  ...original,
  accessToken: "new-access",
  refreshToken: "new-refresh",
  expiresAt: 10_000_000
}
const gate = <T = void>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => {
    resolve = done
  })
  return { promise, resolve }
}
const fixture = () => {
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

describe("encrypted shared credential vault", () => {
  it("authenticates the credential id and rejects modified ciphertext and wrong keys", () => {
    const ref = { id: "a", key: Buffer.alloc(32, 1).toString("base64url") }
    const sealed = sealSharedCredential(ref, original)
    expect(sealed).not.toContain("old-refresh")
    expect(openSharedCredential(ref, sealed)).toEqual(original)
    expect(() => openSharedCredential({ ...ref, id: "b" }, sealed)).toThrow()
    expect(() =>
      openSharedCredential({ ...ref, key: Buffer.alloc(32, 2).toString("base64url") }, sealed)
    ).toThrow()
    const bytes = Buffer.from(sealed, "base64url")
    bytes[29] = bytes[29]! ^ 1
    expect(() => openSharedCredential(ref, bytes.toString("base64url"))).toThrow()
    expect(() =>
      openSharedCredential(ref, sealSharedCredential(ref, { ...original, expiresAt: NaN }))
    ).toThrow("Invalid shared credential")
    expect(
      openSharedCredential(
        ref,
        sealSharedCredential(ref, { ...original, harnessId: "claude-code" })
      ).harnessId
    ).toBe("claude-code")
  })

  it.each(["codex", "pi", "opencode", "grok-build"] as const)(
    "serializes two machines refreshing %s and publishes both tokens in one generation",
    async (harnessId) => {
      const fixture_ = fixture()
      const entered = gate(),
        release = gate(),
        waiting = gate()
      const rotate = vi.fn(async () => {
        entered.resolve()
        await release.promise
        return { ...refreshed, harnessId }
      })
      const a = makeSharedCredentialVault({ ...fixture_.config, rotate })
      const b = makeSharedCredentialVault({
        ...fixture_.config,
        rotate,
        coordinate: fixture_.coordinate("b"),
        wait: async () => {
          waiting.resolve()
          await release.promise
        }
      })
      const ref = await a.create({ ...original, harnessId })
      const first = a.token(ref)
      await entered.promise
      const second = b.token(ref)
      await waiting.promise
      release.resolve()
      expect(await first).toEqual({ ...refreshed, harnessId })
      expect(await second).toEqual({ ...refreshed, harnessId })
      expect(rotate).toHaveBeenCalledOnce()
      expect(fixture_.records.get(ref.id)?.generation).toBe(2)
      expect(fixture_.receipts.size).toBe(0)
    }
  )

  it("recovers a lost commit response without replaying the provider exchange", async () => {
    const f = fixture()
    let loseCommit = true
    const coordinate: CredentialCoordinator = async (id, command) => {
      const result = await f.config.coordinate(id, command)
      if (command.action === "commit" && loseCommit) {
        loseCommit = false
        throw new Error("lost response")
      }
      return result
    }
    const config = { ...f.config, coordinate }
    const vault = makeSharedCredentialVault(config)
    const ref = await vault.create(original)
    await expect(vault.token(ref)).rejects.toThrow("lost response")
    expect(f.receipts.size).toBe(1)
    expect(await makeSharedCredentialVault(config).token(ref)).toEqual(refreshed)
    expect(f.config.rotate).toHaveBeenCalledOnce()
    expect(f.receipts.size).toBe(0)
  })

  it("does not replay an ambiguous refresh, even after the lease deadline", async () => {
    const f = fixture()
    const rotate = vi.fn(async () => {
      throw new Error("provider may have consumed token")
    })
    const a = makeSharedCredentialVault({ ...f.config, rotate })
    const ref = await a.create(original)
    await expect(a.token(ref)).rejects.toThrow("Sign in again")
    f.setTime(200_000)
    const b = makeSharedCredentialVault({ ...f.config, rotate, coordinate: f.coordinate("b") })
    await expect(b.token(ref)).rejects.toThrow("Sign in again")
    expect(rotate).toHaveBeenCalledOnce()
  })

  it("uses unexpired cached access offline but never independently refreshes it", async () => {
    const f = fixture()
    let offline = false
    const vault = makeSharedCredentialVault({
      ...f.config,
      coordinate: async (...args) => {
        if (offline) throw new Error("offline")
        return f.config.coordinate(...args)
      }
    })
    const ref = await vault.create(refreshed)
    offline = true
    expect(await vault.token(ref)).toEqual(refreshed)
    await expect(vault.token(ref, refreshed.accessToken)).rejects.toThrow(
      "Account sync is unavailable"
    )
    f.setTime(refreshed.expiresAt)
    await expect(vault.token(ref)).rejects.toThrow("Account sync is unavailable")
    expect(f.config.rotate).not.toHaveBeenCalled()
  })

  it("forces refresh on rejection, but accepts a newer token another machine already published", async () => {
    const f = fixture()
    const vault = makeSharedCredentialVault(f.config)
    const ref = await vault.create({ ...original, expiresAt: refreshed.expiresAt })
    expect((await vault.token(ref, original.accessToken)).accessToken).toBe(refreshed.accessToken)
    expect((await vault.token(ref, original.accessToken)).accessToken).toBe(refreshed.accessToken)
    expect(f.config.rotate).toHaveBeenCalledOnce()
  })

  it("never rotates an external CLI grant and mirrors only newer access tokens", async () => {
    const f = fixture()
    const vault = makeSharedCredentialVault(f.config)
    const external: SharedTokenBundle = {
      ...original,
      ownership: "external",
      refreshToken: undefined
    } as unknown as SharedTokenBundle
    const ref = await vault.create(external)
    await expect(vault.token(ref)).rejects.toThrow("Sign in again")
    const updated = { ...external, accessToken: "native-new", expiresAt: refreshed.expiresAt }
    await vault.publishExternal(ref, updated)
    expect(await vault.token(ref)).toEqual(updated)
    await vault.publishExternal(ref, external)
    expect(await vault.token(ref)).toEqual(updated)
    expect(f.config.rotate).not.toHaveBeenCalled()
  })

  it("rejects cross-account refreshes and globally revoked credentials", async () => {
    const f = fixture()
    const vault = makeSharedCredentialVault({
      ...f.config,
      rotate: async () => ({ ...refreshed, subject: "different" })
    })
    const ref = await vault.create(original)
    await expect(vault.token(ref)).rejects.toThrow("Sign in again")
    await vault.revoke(ref)
    await expect(vault.token(ref)).rejects.toThrow("signed out")
    expect(f.records.get(ref.id)?.sealed).toBe("")
  })

  it("bounds waiting for another machine without stealing its refresh", async () => {
    const f = fixture()
    const a = makeSharedCredentialVault(f.config)
    const ref = await a.create(original)
    await f.config.coordinate(ref.id, { action: "acquire", generation: 1, operationId: "held" })
    const b = makeSharedCredentialVault({
      ...f.config,
      coordinate: f.coordinate("b"),
      wait: async () => f.setTime(108_000)
    })
    await expect(b.token(ref)).rejects.toThrow("reconnecting")
    expect(f.config.rotate).not.toHaveBeenCalled()
  })
  it("coalesces concurrent callers, including an unauthorized caller that arrives during a normal read", async () => {
    const f = fixture(),
      held = gate(),
      entered = gate()
    let hold = true
    const vault = makeSharedCredentialVault({
      ...f.config,
      coordinate: async (id, command) => {
        if (command.action === "read" && hold) {
          entered.resolve()
          await held.promise
        }
        return f.config.coordinate(id, command)
      }
    })
    const ref = await vault.create({ ...original, expiresAt: refreshed.expiresAt })
    const first = vault.token(ref)
    await entered.promise
    const same = vault.token(ref)
    const unauthorized = vault.token(ref, original.accessToken)
    hold = false
    held.resolve()
    expect((await first).accessToken).toBe(original.accessToken)
    expect((await same).accessToken).toBe(original.accessToken)
    expect((await unauthorized).accessToken).toBe(refreshed.accessToken)
    expect(f.config.rotate).toHaveBeenCalledOnce()
  })

  it("reads a competing commit before acquiring a now-obsolete generation", async () => {
    const f = fixture()
    let raced = false
    const vault = makeSharedCredentialVault({
      ...f.config,
      coordinate: async (id, command) => {
        if (command.action === "acquire" && !raced) {
          raced = true
          f.records.set(id, {
            generation: 2,
            sealed: sealSharedCredential(ref, refreshed),
            revoked: false
          })
        }
        return f.config.coordinate(id, command)
      }
    })
    const ref = await vault.create(original)
    expect(await vault.token(ref)).toEqual(refreshed)
    expect(f.config.rotate).not.toHaveBeenCalled()
  })

  it.each(["acquire", "start", "commit"] as const)(
    "honors a global sign-out racing with %s",
    async (phase) => {
      const f = fixture()
      const vault = makeSharedCredentialVault({
        ...f.config,
        coordinate: async (id, command) => {
          if (command.action === phase) await f.coordinate("b")(id, { action: "revoke" })
          return f.config.coordinate(id, command)
        }
      })
      const ref = await vault.create(original)
      await expect(vault.token(ref)).rejects.toThrow(
        phase === "start" ? "Sign in again" : "signed out"
      )
      if (phase !== "commit") expect(f.config.rotate).not.toHaveBeenCalled()
      else
        await expect(makeSharedCredentialVault(f.config).token(ref)).rejects.toThrow("signed out")
    }
  )

  it("requires reconnecting when publication is refused and never discards the recoverable receipt", async () => {
    const f = fixture()
    const vault = makeSharedCredentialVault({
      ...f.config,
      coordinate: async (id, command) =>
        command.action === "commit" ? { status: "uncertain" } : f.config.coordinate(id, command)
    })
    const ref = await vault.create(original)
    await expect(vault.token(ref)).rejects.toThrow("Sign in again")
    expect(f.receipts.size).toBe(1)
    await expect(vault.token(ref)).rejects.toThrow("Sign in again")
    expect(f.config.rotate).toHaveBeenCalledOnce()
  })

  it("distinguishes a missing grant from a disconnected first-time machine", async () => {
    const f = fixture(),
      ref = { id: "missing", key: Buffer.alloc(32).toString("base64url") }
    await expect(makeSharedCredentialVault(f.config).token(ref)).rejects.toThrow("Sign in again")
    const offline = makeSharedCredentialVault({
      ...f.config,
      coordinate: async () => {
        throw new Error("offline")
      }
    })
    await expect(offline.token(ref)).rejects.toThrow("unavailable")
    await expect(
      makeSharedCredentialVault({
        ...f.config,
        coordinate: async () => ({ status: "busy" })
      }).revoke(ref)
    ).rejects.toThrow("unavailable")
    await makeSharedCredentialVault(f.config).revoke(ref)
  })

  it("waits using the production scheduler until the owner publishes", async () => {
    vi.useFakeTimers()
    try {
      const f = fixture(),
        entered = gate()
      const { now: _now, elapsed: _elapsed, ...config } = f.config
      const vault = makeSharedCredentialVault({
        ...config,
        coordinate: async (id, command) => {
          if (command.action === "acquire") entered.resolve()
          return f.coordinate("b")(id, command)
        }
      })
      const ref = await vault.create(original)
      await f.config.coordinate(ref.id, { action: "acquire", generation: 1, operationId: "held" })
      const pending = vault.token(ref)
      await entered.promise
      f.records.set(ref.id, {
        generation: 2,
        sealed: sealSharedCredential(ref, { ...refreshed, expiresAt: Date.now() + 1_000_000 }),
        revoked: false
      })
      await vi.advanceTimersByTimeAsync(150)
      expect((await pending).accessToken).toBe(refreshed.accessToken)
    } finally {
      vi.useRealTimers()
    }
  })

  it("keeps an external publisher from replacing a managed grant or another account", async () => {
    const f = fixture(),
      vault = makeSharedCredentialVault(f.config)
    const ref = await vault.create(refreshed)
    await expect(vault.publishExternal(ref, refreshed)).rejects.toThrow(
      "Invalid external credential"
    )
    const { refreshToken: _refresh, ...access } = refreshed
    await vault.publishExternal(ref, { ...access, ownership: "external", accessToken: "external" })
    expect(await vault.token(ref)).toEqual(refreshed)
  })

  it.each(["acquire", "start", "commit"] as const)(
    "handles a competing external publication at %s",
    async (phase) => {
      const f = fixture()
      const vault = makeSharedCredentialVault({
        ...f.config,
        coordinate: async (id, command) =>
          command.action === phase ? { status: "busy" } : f.config.coordinate(id, command)
      })
      const { refreshToken: _refresh, ...access } = original
      const ref = await vault.create({ ...access, ownership: "external" })
      const publication = vault.publishExternal(ref, {
        ...access,
        accessToken: "new",
        expiresAt: 200_000,
        ownership: "external"
      })
      if (phase === "commit") await expect(publication).rejects.toThrow("unavailable")
      else await publication
      expect(f.config.rotate).not.toHaveBeenCalled()
    }
  )
})

it("restores only a valid account-bound encrypted cache after restart", async () => {
  const f = fixture()
  const originalVault = makeSharedCredentialVault(f.config)
  const reference = await originalVault.create(refreshed)
  const readCached = vi.fn(async () => f.records.get(reference.id))
  const vault = makeSharedCredentialVault({
    ...f.config,
    coordinate: async () => {
      throw new Error("offline")
    },
    readCached
  })
  expect(await vault.token(reference)).toEqual(refreshed)
  readCached.mockResolvedValueOnce(undefined)
  await expect(vault.token(reference)).rejects.toThrow("when connected")
  readCached.mockRejectedValueOnce(new Error("unreadable"))
  await expect(vault.token(reference)).rejects.toThrow("when connected")
  readCached.mockResolvedValueOnce({ generation: 2, sealed: "", revoked: true })
  await expect(vault.token(reference)).rejects.toThrow("signed out")
})
