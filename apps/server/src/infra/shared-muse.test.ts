import { mkdir, readFile, readlink, stat } from "node:fs/promises"
import { join } from "node:path"

import { parseMuseAuth, sharedOAuthIdentity } from "@codevisor/harness-manager"
import { describe, expect, it, vi } from "vitest"

import { fleet } from "./shared-accounts-test-support.js"

const meta = {
  access_token: "access-1",
  api_key: "LLM|1|key",
  mechanism: "oauth",
  obtained_via: "device_code",
  api_base_url: "https://api.meta.ai/v1",
  subs_active: true
}
const signIn = parseMuseAuth({ schema_version: 1, providers: { meta } }, "managed")!

describe("Muse Code account sync", () => {
  it("captures a Muse sign-in once and writes it into every machine's own Muse profile", async () => {
    const f = fleet(),
      a = await f.machine("a"),
      b = await f.machine("b")
    const placeholder = await a.shared.create("muse-code")
    const fresh = await a.shared.prepareLogin(placeholder.id)
    a.setBundle(signIn)
    await a.shared.captureLogin(fresh)
    a.setBundle(undefined)
    await f.sync(a, b)

    const id = sharedOAuthIdentity(signIn)
    const [account] = (await b.shared.accounts("muse-code", true))!
    expect(account).toMatchObject({ id, label: "Meta", authState: "authenticated" })

    await mkdir(join(b.dataDir, ".config", "gh"), { recursive: true })
    const context = (await b.shared.context(id))!
    const profile = join(b.dataDir, "harness-profiles", "muse-code", id)
    expect(context).toEqual({
      id,
      profileKind: "managed",
      env: { XDG_CONFIG_HOME: join(profile, "config"), TBH_CREDENTIAL_BACKEND: "file" },
      unsetEnv: ["META_API_KEY"]
    })
    const written = join(profile, "config", "muse", "auth.json")
    expect(JSON.parse(await readFile(written, "utf8"))).toEqual({
      schema_version: 1,
      providers: { meta }
    })
    expect((await stat(written)).mode & 0o777).toBe(0o600)
    expect(await readlink(join(profile, "config", "gh"))).toBe(join(b.dataDir, ".config", "gh"))
    expect(f.rotate).not.toHaveBeenCalled()

    await a.shared.context(id)
    await a.shared.logout(id, true)
    await expect(
      stat(join(a.dataDir, "harness-profiles", "muse-code", id, "config", "muse", "auth.json"))
    ).rejects.toMatchObject({ code: "ENOENT" })
    await f.sync(a, b)
    await expect(b.shared.context(id)).rejects.toThrow()
  })

  it("syncs a Meta API key as META_API_KEY, never as a file", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(100_000)
    try {
      const f = fleet(),
        a = await f.machine("a"),
        b = await f.machine("b")
      const placeholder = await a.shared.create("muse-code")
      await a.shared.saveApiKey(placeholder.id, "meta-api-secret")
      await f.sync(a, b)
      const accounts = (await b.shared.accounts("muse-code", true))!
      expect(accounts).toHaveLength(1)
      expect(JSON.stringify(accounts)).not.toContain("meta-api-secret")
      const context = (await b.shared.context(accounts[0]!.id))!
      expect(context.env).toMatchObject({
        META_API_KEY: "meta-api-secret",
        TBH_CREDENTIAL_BACKEND: "file"
      })
      expect(context.unsetEnv).toBeUndefined()
      await expect(
        stat(join(context.env!.XDG_CONFIG_HOME!, "muse", "auth.json"))
      ).rejects.toMatchObject({ code: "ENOENT" })
    } finally {
      vi.useRealTimers()
    }
  })
})
