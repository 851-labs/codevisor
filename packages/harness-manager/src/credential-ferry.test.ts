import { rmSync } from "node:fs"
import { mkdtemp, readFile, writeFile, mkdir, stat } from "node:fs/promises"
import { homedir, tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it, vi } from "vitest"

import { credentialFerrySources, canonicalCredentialJson } from "./credential-ferry.js"

const roots: string[] = []
afterEach(() => {
  vi.unstubAllEnvs()
  for (const root of roots.splice(0)) rmSync(root, { force: true, recursive: true })
})

const makeSources = async () => {
  const home = await mkdtemp(join(tmpdir(), "codevisor-ferry-"))
  roots.push(home)
  const env = { HOME: home, XDG_DATA_HOME: join(home, ".local", "share") }
  const sources = credentialFerrySources({ resolveEnv: () => Promise.resolve(env) })
  const byId = Object.fromEntries(sources.map((source) => [source.id, source]))
  return { home, byId }
}

describe("pi source", () => {
  it("keeps machine API-key overrides out of shared state and preserves them when shared keys change", async () => {
    const { home } = await makeSources()
    const sources = credentialFerrySources({
      resolveEnv: async () => ({ HOME: home }),
      localProviders: async () => ["openai"]
    })
    for (const [id, path, type] of [
      ["pi-auth", join(home, ".pi", "agent", "auth.json"), "api_key"],
      ["opencode-auth", join(home, ".local", "share", "opencode", "auth.json"), "api"]
    ]) {
      const source = sources.find((source) => source.id === id)!
      await mkdir(join(path!, ".."), { recursive: true })
      await writeFile(path!, JSON.stringify({ openai: { type, key: "machine-key" } }))
      const shared = JSON.stringify({ openai: { type, key: "shared-key" } })
      expect(await source.localOverrides!()).toContain("openai")
      expect(await source.read()).toBe("{}")
      expect(JSON.parse((await source.read(shared))!)).toEqual(JSON.parse(shared))
      await source.apply(
        JSON.stringify({ openai: { type, key: "changed-shared" }, google: { type, key: "other" } })
      )
      expect(JSON.parse(await readFile(path!, "utf8"))).toEqual({
        openai: { type, key: "machine-key" },
        google: { type, key: "other" }
      })
      await writeFile(path!, "{}")
      expect(JSON.parse((await source.read(shared))!)).toEqual(JSON.parse(shared))
    }
  })
  it("publishes only api_key entries and grafts them without touching oauth", async () => {
    const { home, byId } = await makeSources()
    const path = join(home, ".pi", "agent", "auth.json")
    await mkdir(join(home, ".pi", "agent"), { recursive: true })
    await writeFile(
      path,
      JSON.stringify({
        anthropic: { type: "oauth", refresh: "r", access: "a", expires: 1 },
        openai: { type: "api_key", key: "sk-1" }
      })
    )
    const source = byId["pi-auth"]!
    expect(source.tombstoneOnAbsence).toBe(false)
    const published = await source.read()
    expect(published).toBe(canonicalCredentialJson({ openai: { type: "api_key", key: "sk-1" } }))

    await source.apply(canonicalCredentialJson({ groq: { type: "api_key", key: "sk-2" } }))
    const merged = JSON.parse(await readFile(path, "utf8")) as Record<string, unknown>
    expect(Object.keys(merged).toSorted()).toEqual(["anthropic", "groq"])
    expect(merged.anthropic).toMatchObject({ type: "oauth", refresh: "r" })
    expect((await stat(path)).mode & 0o777).toBe(0o600)
  })

  it("publishes nothing when the file is absent, and applies onto a fresh machine", async () => {
    const { home, byId } = await makeSources()
    const source = byId["pi-auth"]!
    expect(await source.read()).toBeUndefined()
    await source.apply(canonicalCredentialJson({ openai: { type: "api_key", key: "sk-9" } }))
    const written = JSON.parse(
      await readFile(join(home, ".pi", "agent", "auth.json"), "utf8")
    ) as Record<string, unknown>
    expect(written.openai).toMatchObject({ key: "sk-9" })
  })
})

describe("opencode source", () => {
  it("keeps a local OAuth sign-in while retaining the shared key it shadows", async () => {
    const { home, byId } = await makeSources()
    const source = byId["opencode-auth"]!
    expect(await source.localOverrides!()).toEqual([])
    const path = join(home, ".local", "share", "opencode", "auth.json")
    await mkdir(join(home, ".local", "share", "opencode"), { recursive: true })
    const oauth = { type: "oauth", access: "local-session" }
    await writeFile(
      path,
      JSON.stringify({ anthropic: oauth, openai: { type: "api", key: "local-key" } })
    )
    const shared = canonicalCredentialJson({ anthropic: { type: "api", key: "shared-key" } })
    expect(await source.localOverrides!()).toEqual(["anthropic"])
    expect(JSON.parse((await source.read(shared))!)).toEqual({
      anthropic: { type: "api", key: "shared-key" },
      openai: { type: "api", key: "local-key" }
    })
    await source.apply(shared)
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({ anthropic: oauth })
    expect(await source.read(shared)).toBe(shared)
    await source.apply("{}")
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({ anthropic: oauth })
    expect(await source.read("{}")).toBe("{}")
  })

  it("ferries api and wellknown entries, never oauth", async () => {
    const { home, byId } = await makeSources()
    const path = join(home, ".local", "share", "opencode", "auth.json")
    await mkdir(join(home, ".local", "share", "opencode"), { recursive: true })
    await writeFile(
      path,
      JSON.stringify({
        anthropic: { type: "oauth", access: "a" },
        openrouter: { type: "api", key: "or-1" },
        cloudflare: { type: "wellknown", key: "cf", token: "t" }
      })
    )
    const source = byId["opencode-auth"]!
    const published = JSON.parse((await source.read())!) as Record<string, unknown>
    expect(Object.keys(published).toSorted()).toEqual(["cloudflare", "openrouter"])
  })
})

describe("codex source", () => {
  it("ferries api-key files but never a live ChatGPT login, either direction", async () => {
    const { home, byId } = await makeSources()
    const path = join(home, ".codex", "auth.json")
    const source = byId["codex-auth-file"]!
    expect(source.tombstoneOnAbsence).toBe(true)
    expect(await source.localOverrides!()).toEqual([])

    await mkdir(join(home, ".codex"), { recursive: true })
    await writeFile(path, JSON.stringify({ OPENAI_API_KEY: "sk-c" }))
    expect(await source.read()).toBe(canonicalCredentialJson({ OPENAI_API_KEY: "sk-c" }))

    await writeFile(path, JSON.stringify({ tokens: { access_token: "a" }, last_refresh: "t" }))
    expect(await source.localOverrides!()).toEqual(["*"])
    expect(await source.read()).toBeUndefined()
    await source.apply(canonicalCredentialJson({ OPENAI_API_KEY: "ferried" }))
    expect(JSON.parse(await readFile(path, "utf8"))).toHaveProperty("tokens")
    await source.applyDelete!()
    expect(JSON.parse(await readFile(path, "utf8"))).toHaveProperty("tokens")

    await writeFile(path, JSON.stringify({ OPENAI_API_KEY: "old" }))
    await source.apply(canonicalCredentialJson({ OPENAI_API_KEY: "ferried" }))
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({ OPENAI_API_KEY: "ferried" })
    await source.applyDelete!()
    expect(await source.read()).toBeUndefined()
    await source.applyDelete!()
  })
})

describe("devin source", () => {
  it("ferries the credentials file verbatim and tombstones on absence", async () => {
    const { home, byId } = await makeSources()
    const source = byId["devin-credentials-file"]!
    expect(source.tombstoneOnAbsence).toBe(true)
    expect(await source.read()).toBeUndefined()

    const path = join(home, ".local", "share", "devin", "credentials.toml")
    await mkdir(join(home, ".local", "share", "devin"), { recursive: true })
    const content = 'windsurf_api_key = "wk-static"\napi_server_url = "https://api.devin.ai"\n'
    await writeFile(path, content)
    expect(await source.read()).toBe(content)

    const { home: other, byId: otherById } = await makeSources()
    const target = otherById["devin-credentials-file"]!
    await target.apply(content)
    const applied = join(other, ".local", "share", "devin", "credentials.toml")
    expect(await readFile(applied, "utf8")).toBe(content)
    expect(((await stat(applied)).mode & 0o777).toString(8)).toBe("600")

    await target.applyDelete!()
    await expect(readFile(applied, "utf8")).rejects.toMatchObject({ code: "ENOENT" })
    await target.applyDelete!()
  })

  it("honors HOME fallback when XDG_DATA_HOME is unset and surfaces read errors", async () => {
    const home = await mkdtemp(join(tmpdir(), "codevisor-ferry-"))
    roots.push(home)
    const sources = credentialFerrySources({
      resolveEnv: () => Promise.resolve({ HOME: home })
    })
    const source = sources.find((candidate) => candidate.id === "devin-credentials-file")!
    await source.apply('windsurf_api_key = "wk"\n')
    expect(
      await readFile(join(home, ".local", "share", "devin", "credentials.toml"), "utf8")
    ).toContain("wk")

    const broken = await mkdtemp(join(tmpdir(), "codevisor-ferry-"))
    roots.push(broken)
    await mkdir(join(broken, ".local", "share", "devin", "credentials.toml"), {
      recursive: true
    })
    const brokenSource = credentialFerrySources({
      resolveEnv: () => Promise.resolve({ HOME: broken })
    }).find((candidate) => candidate.id === "devin-credentials-file")!
    await expect(brokenSource.read()).rejects.toThrow()

    vi.stubEnv("HOME", home)
    expect(homedir()).toBe(home)
    const bare = credentialFerrySources({ resolveEnv: () => Promise.resolve({}) }).find(
      (candidate) => candidate.id === "devin-credentials-file"
    )!
    expect(await bare.read()).toBe('windsurf_api_key = "wk"\n')
  })
})

describe("hostile files and path variants", () => {
  it("rejects non-object files, surfaces read errors, and honors dir overrides", async () => {
    const home = await mkdtemp(join(tmpdir(), "codevisor-ferry-h-"))
    roots.push(home)

    const env = {
      HOME: home,
      XDG_DATA_HOME: join(home, ".local", "share"),
      PI_CODING_AGENT_DIR: "~/custom-pi",
      CODEX_HOME: join(home, "custom-codex")
    }
    const sources = credentialFerrySources({ resolveEnv: () => Promise.resolve(env) })
    const byId = Object.fromEntries(sources.map((source) => [source.id, source]))

    await mkdir(join(home, "custom-pi"), { recursive: true })
    await writeFile(
      join(home, "custom-pi", "auth.json"),
      JSON.stringify({ openai: { type: "api_key", key: "sk-custom" }, junk: "not-an-object" })
    )
    expect(await byId["pi-auth"]!.read()).toBe(
      canonicalCredentialJson({ openai: { type: "api_key", key: "sk-custom" } })
    )
    await byId["pi-auth"]!.apply(canonicalCredentialJson({ a: { type: "api_key", key: "1" } }))
    await byId["pi-auth"]!.apply(canonicalCredentialJson({ a: { type: "api_key", key: "2" } }))

    await mkdir(join(home, "custom-codex"), { recursive: true })
    await writeFile(join(home, "custom-codex", "auth.json"), JSON.stringify(["an", "array"]))
    await expect(byId["codex-auth-file"]!.read()).rejects.toThrow("Not a credential object")

    const { chmod } = await import("node:fs/promises")
    await writeFile(
      join(home, "custom-codex", "auth.json"),
      '{"OPENAI_API_KEY":"permission-fixture"}'
    )
    await chmod(join(home, "custom-codex", "auth.json"), 0o000)
    try {
      await expect(byId["codex-auth-file"]!.read()).rejects.toMatchObject({ code: "EACCES" })
    } finally {
      await chmod(join(home, "custom-codex", "auth.json"), 0o600)
    }

    const lockedHome = await mkdtemp(join(tmpdir(), "codevisor-ferry-l-"))
    roots.push(lockedHome)
    const lockedDir = join(lockedHome, "custom-pi")
    await mkdir(lockedDir, { recursive: true })
    const { chmod: chmodDir } = await import("node:fs/promises")
    await chmodDir(lockedDir, 0o500)
    try {
      const locked = credentialFerrySources({
        resolveEnv: () => Promise.resolve({ HOME: lockedHome, PI_CODING_AGENT_DIR: lockedDir })
      }).find((source) => source.id === "pi-auth")!
      await expect(
        locked.apply(canonicalCredentialJson({ a: { type: "api_key", key: "x" } }))
      ).rejects.toMatchObject({ code: "EACCES" })
    } finally {
      await chmodDir(lockedDir, 0o700)
    }

    const emptied = credentialFerrySources({
      resolveEnv: () => Promise.resolve({ HOME: home, PI_CODING_AGENT_DIR: "", CODEX_HOME: "" })
    })
    expect(await emptied.find((source) => source.id === "pi-auth")!.read()).toBeUndefined()

    vi.stubEnv("HOME", home)
    expect(homedir()).toBe(home)
    await mkdir(join(home, ".codex"), { recursive: true })
    await writeFile(join(home, ".codex", "auth.json"), '{"OPENAI_API_KEY":"owned-fallback"}')
    await mkdir(join(home, ".pi", "agent"), { recursive: true })
    await writeFile(
      join(home, ".pi", "agent", "auth.json"),
      '{"openai":{"type":"api_key","key":"owned-pi"}}'
    )
    const bare = credentialFerrySources({
      resolveEnv: () => Promise.resolve({ PI_CODING_AGENT_DIR: "~/nowhere-pi" })
    })
    const pi = bare.find((source) => source.id === "pi-auth")!
    expect(await pi.read()).toBeUndefined()
    const codexBare = bare.find((source) => source.id === "codex-auth-file")!
    expect(await codexBare.read()).toBe('{"OPENAI_API_KEY":"owned-fallback"}')
    const emptyEnv = credentialFerrySources({ resolveEnv: () => Promise.resolve({}) })
    expect(await emptyEnv.find((source) => source.id === "pi-auth")!.read()).toBe(
      '{"openai":{"type":"api_key","key":"owned-pi"}}'
    )
  })
})
