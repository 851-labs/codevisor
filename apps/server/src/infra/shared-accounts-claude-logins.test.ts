import { join } from "node:path"

import { sharedOAuthIdentity, type SharedTokenBundle } from "@codevisor/harness-manager"
import { Effect } from "effect"
import { afterEach, describe, expect, it, onTestFinished, vi } from "vitest"

import { fleet, native } from "./shared-accounts-test-support.js"

afterEach(() => vi.useRealTimers())

const machineLogin = (accessToken = "machine-access"): SharedTokenBundle => ({
  ...native("alice"),
  harnessId: "claude-code",
  accessToken
})
const codevisorLogin: SharedTokenBundle = {
  ...machineLogin("codevisor-access"),
  ownership: "managed",
  refreshToken: "codevisor-refresh",
  expiresAt: 1
}
const accountId = sharedOAuthIdentity(machineLogin())
const profileOf = (dataDir: string, id: string) =>
  join(dataDir, "harness-profiles", "claude-code", id)

const signedInThroughCodevisor = async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(100_000)
  const m = await fleet().machine("a")
  const placeholder = await m.shared.create("claude-code")
  const loginProfile = await m.shared.prepareLogin(placeholder.id)
  m.setBundle(codevisorLogin)
  await m.shared.captureLogin(loginProfile)
  m.setBundle(undefined)
  return { m, loginProfile }
}

describe("keeping one copy of each Claude refresh token", () => {
  it("removes the sign-in profile's login once the vault holds it", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    const m = await fleet().machine("a")
    const vaultHeldIt: boolean[] = []
    m.forgetProfileLogin.mockImplementation(async () => {
      vaultHeldIt.push((await m.shared.store.get(accountId))?.credential !== undefined)
      return true
    })
    const placeholder = await m.shared.create("claude-code")
    const loginProfile = await m.shared.prepareLogin(placeholder.id)
    m.setBundle(codevisorLogin)

    await m.shared.captureLogin(loginProfile)

    expect(m.forgetProfileLogin).toHaveBeenCalledExactlyOnceWith(
      profileOf(m.dataDir, loginProfile),
      expect.anything()
    )
    expect(vaultHeldIt).toEqual([true])
  })

  it("completes the sign-in when the leftover login cannot be removed", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    const m = await fleet().machine("a")
    m.forgetProfileLogin.mockRejectedValue(new Error("Keychain locked"))
    const errors = vi.spyOn(console, "error").mockImplementation(() => {})
    onTestFinished(() => errors.mockRestore())
    const placeholder = await m.shared.create("claude-code")
    const loginProfile = await m.shared.prepareLogin(placeholder.id)
    m.setBundle(codevisorLogin)

    await m.shared.captureLogin(loginProfile)

    expect((await m.shared.probe(accountId))?.authState).toBe("authenticated")
    expect(errors).toHaveBeenCalledWith(expect.stringContaining("Keychain locked"))
  })

  it("sweeps retired Claude profiles once per start, never a pending sign-in or the machine login", async () => {
    const { m, loginProfile } = await signedInThroughCodevisor()
    const pending = await m.shared.prepareLogin(accountId)
    await Effect.runPromise(
      m.db.saveHarnessAccount({
        id: "machine-login",
        harnessId: "claude-code",
        profileKind: "default",
        label: "Claude",
        authState: "authenticated",
        canLogin: true,
        canLogout: true
      })
    )
    const restarted = m.restart()
    m.forgetProfileLogin.mockClear()

    await restarted.reconcile()
    await restarted.reconcile()

    const swept = m.forgetProfileLogin.mock.calls.map(([directory]) => directory)
    expect(swept).toContain(profileOf(m.dataDir, loginProfile))
    expect(swept).toContain(profileOf(m.dataDir, accountId))
    expect(swept).not.toContain(profileOf(m.dataDir, pending))
    expect(swept).not.toContain(profileOf(m.dataDir, "machine-login"))
    expect(new Set(swept).size).toBe(swept.length)
  })
})

describe("Claude session profiles never keep their own login", () => {
  it("clears the session profile's login before handing out a session, at most every five minutes", async () => {
    const { m } = await signedInThroughCodevisor()
    const sessionProfile = profileOf(m.dataDir, accountId)
    const sessionClears = () =>
      m.forgetProfileLogin.mock.calls.filter(([directory]) => directory === sessionProfile).length

    await m.shared.context(accountId)
    await m.shared.context(accountId)
    expect(sessionClears()).toBe(1)

    vi.setSystemTime(100_000 + 5 * 60_000)
    await m.shared.context(accountId)
    expect(sessionClears()).toBe(2)
  })
})
