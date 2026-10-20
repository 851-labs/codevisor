import { randomBytes } from "node:crypto"

import { describe, expect, it } from "vitest"

import { fixture, original, refreshed } from "./shared-credential-vault-test-support.js"
import { makeSharedCredentialVault } from "./shared-credential-vault.js"

const reference = () => ({
  id: "takeover-0123456789abcdef",
  key: randomBytes(32).toString("base64url")
})

describe("claiming a credential slot", () => {
  it("replaces its own stale login when a claim is retried with the same key", async () => {
    const f = fixture()
    const vault = makeSharedCredentialVault(f.config)
    const slot = reference()
    await vault.claim(slot, original)

    expect(await vault.claim(slot, refreshed)).toBe(true)

    expect(await vault.confirm(slot, refreshed)).toBe(true)
    expect(await vault.confirm(slot, original)).toBe(false)
  })

  it("reports busy instead of replacing a stale login while another holder has the slot's lease", async () => {
    const f = fixture()
    const vault = makeSharedCredentialVault(f.config)
    const slot = reference()
    await vault.claim(slot, original)
    await f.coordinate("b")(slot.id, { action: "acquire", generation: 1, operationId: "other" })

    await expect(vault.claim(slot, refreshed)).rejects.toMatchObject({ reason: "busy" })

    expect(await vault.confirm(slot, original)).toBe(true)
  })

  it("stops confirming a slot that was revoked", async () => {
    const f = fixture()
    const vault = makeSharedCredentialVault(f.config)
    const slot = reference()
    await vault.claim(slot, original)

    await vault.revoke(slot)

    expect(await vault.confirm(slot, original)).toBe(false)
    expect(await vault.claim(slot, original)).toBe(false)
  })

  it("leaves a slot another key already holds untouched", async () => {
    const f = fixture()
    const winner = makeSharedCredentialVault(f.config)
    const loser = makeSharedCredentialVault({ ...f.config, coordinate: f.coordinate("b") })
    const slot = reference()
    await winner.claim(slot, original)

    expect(await loser.claim({ ...slot, key: reference().key }, refreshed)).toBe(false)

    expect(await winner.confirm(slot, original)).toBe(true)
  })
})
