import { mkdir, readFile, stat, writeFile } from "node:fs/promises"
import { join } from "node:path"

import {
  antigravityAuthPath,
  parseAntigravityAuth,
  sharedOAuthIdentity
} from "@codevisor/harness-manager"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { fleet } from "./shared-accounts-test-support.js"

const claims = Buffer.from(JSON.stringify({ email: "Dev@Example.com" })).toString("base64url")
const document = {
  token: {
    access_token: "ya29.access-1",
    token_type: "Bearer",
    refresh_token: "1//refresh-1",
    expiry: "2026-10-13T19:14:00.000000-07:00"
  },
  auth_method: "consumer",
  id_token: `header.${claims}.signature`
}
const signIn = parseAntigravityAuth(document, "managed")!

const readJson = async (path: string) => JSON.parse(await readFile(path, "utf8")) as unknown

describe("Antigravity account sync", () => {
  it("captures a Google sign-in once and writes it into every machine's own agy profile", async () => {
    const f = fleet(),
      a = await f.machine("a"),
      b = await f.machine("b")
    const placeholder = await a.shared.create("antigravity")
    const fresh = await a.shared.prepareLogin(placeholder.id)
    a.setBundle(signIn)
    await a.shared.captureLogin(fresh)
    a.setBundle(undefined)
    await f.sync(a, b)

    const id = sharedOAuthIdentity(signIn)
    const [account] = (await b.shared.accounts("antigravity", true))!
    expect(account).toMatchObject({
      id,
      label: "Dev@Example.com",
      email: "Dev@Example.com",
      authState: "authenticated"
    })

    const profile = join(b.dataDir, "harness-profiles", "antigravity", id)
    expect(await b.shared.context(id)).toEqual({
      id,
      profileKind: "managed",
      env: { CODEVISOR_AGY_GEMINI_DIR: join(profile, "gemini") },
      unsetEnv: ["GEMINI_API_KEY"]
    })
    const written = antigravityAuthPath(profile)
    expect(await readJson(written)).toEqual(document)
    expect((await stat(written)).mode & 0o777).toBe(0o600)

    const refreshed = { ...document, token: { ...document.token, access_token: "ya29.access-2" } }
    await writeFile(written, JSON.stringify(refreshed))
    await b.shared.context(id)
    expect(await readJson(written)).toEqual(refreshed)
    expect(f.rotate).not.toHaveBeenCalled()

    await a.shared.context(id)
    await a.shared.logout(id, true)
    await expect(
      stat(antigravityAuthPath(join(a.dataDir, "harness-profiles", "antigravity", id)))
    ).rejects.toMatchObject({ code: "ENOENT" })
    await f.sync(a, b)
    await expect(b.shared.context(id)).rejects.toThrow()
  })

  it("syncs a Gemini API key with agy's provider set to match, never as a file", async () => {
    const f = fleet(),
      a = await f.machine("a"),
      b = await f.machine("b")
    const placeholder = await a.shared.create("antigravity")
    await a.shared.saveApiKey(placeholder.id, "AIza-gemini-secret")
    await f.sync(a, b)
    const accounts = (await b.shared.accounts("antigravity", true))!
    expect(accounts).toHaveLength(1)
    expect(accounts[0]!.label).toBe("Gemini API key ••••cret")
    expect(JSON.stringify(accounts)).not.toContain("AIza-gemini-secret")
    const id = accounts[0]!.id
    const context = (await b.shared.context(id))!
    const gemini = join(b.dataDir, "harness-profiles", "antigravity", id, "gemini")
    expect(context).toEqual({
      id,
      profileKind: "managed",
      env: { CODEVISOR_AGY_GEMINI_DIR: gemini, GEMINI_API_KEY: "AIza-gemini-secret" }
    })
    expect(await readJson(join(gemini, "antigravity-cli", "settings.json"))).toEqual({
      modelProvider: "gemini"
    })
    await expect(
      stat(antigravityAuthPath(join(b.dataDir, "harness-profiles", "antigravity", id)))
    ).rejects.toMatchObject({ code: "ENOENT" })
  })

  it("leaves a sign-in interrupted by a restart to its capture instead of adopting it early", async () => {
    const a = await fleet().machine("a")
    const placeholder = await a.shared.create("antigravity")
    const fresh = await a.shared.prepareLogin(placeholder.id)
    a.setBundle(signIn)
    const restarted = a.restart()
    const ids = async () =>
      (await restarted.accounts("antigravity", true))!.map((account) => account.id)

    await restarted.reconcile()
    expect(await ids()).toEqual([placeholder.id])

    await restarted.captureLogin(fresh)
    expect(await ids()).toEqual([sharedOAuthIdentity(signIn)])
  })

  it("brings an account signed in before sync into the fleet, keeping its conversations", async () => {
    const f = fleet(),
      a = await f.machine("a"),
      b = await f.machine("b")
    const save = (id: string, profileKind: "managed" | "default") =>
      Effect.runPromise(
        a.db.saveHarnessAccount({
          id,
          harnessId: "antigravity",
          label: "Account 2b8f8d",
          profileKind,
          ...(profileKind === "managed" ? { profileKey: id } : {}),
          authState: "authenticated",
          canLogin: true,
          canLogout: true
        })
      )
    await save("local-1", "managed")
    await save("default-1", "default")
    await a.shared.reconcile()
    expect(await a.shared.accounts("antigravity", true)).toEqual([])
    a.setBundle(signIn)
    await a.shared.reconcile()
    await a.shared.reconcile()
    a.setBundle(undefined)

    const id = sharedOAuthIdentity(signIn)
    expect(
      (await a.shared.accounts("antigravity", true))!.map((account) => [account.id, account.label])
    ).toEqual([[id, "Dev@Example.com"]])
    const original = join(a.dataDir, "harness-profiles", "antigravity", "local-1")
    await mkdir(original, { recursive: true })
    expect((await a.shared.context("local-1"))!.env).toEqual({
      CODEVISOR_AGY_GEMINI_DIR: join(original, "gemini")
    })
    await f.sync(a, b)
    expect((await b.shared.accounts("antigravity", true))![0]).toMatchObject({
      id,
      authState: "authenticated"
    })
  })
})
