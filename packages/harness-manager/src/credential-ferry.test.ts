import { mkdtemp, readFile, writeFile, mkdir, stat } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { rmSync } from "node:fs"
import { credentialFerrySources, canonicalCredentialJson } from "./credential-ferry.js"

const roots: string[] = []
afterEach(() => {
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

    // Applying a fleet subset replaces the api_key class (removals travel)
    // and preserves the local oauth entry verbatim.
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

    // API-key file publishes whole.
    await mkdir(join(home, ".codex"), { recursive: true })
    await writeFile(path, JSON.stringify({ OPENAI_API_KEY: "sk-c" }))
    expect(await source.read()).toBe(canonicalCredentialJson({ OPENAI_API_KEY: "sk-c" }))

    // A rotating token family stops publication…
    await writeFile(path, JSON.stringify({ tokens: { access_token: "a" }, last_refresh: "t" }))
    expect(await source.read()).toBeUndefined()
    // …and refuses ferried content and deletions while it lives.
    await source.apply(canonicalCredentialJson({ OPENAI_API_KEY: "ferried" }))
    expect(JSON.parse(await readFile(path, "utf8"))).toHaveProperty("tokens")
    await source.applyDelete!()
    expect(JSON.parse(await readFile(path, "utf8"))).toHaveProperty("tokens")

    // Back to an API key: applies and deletes propagate.
    await writeFile(path, JSON.stringify({ OPENAI_API_KEY: "old" }))
    await source.apply(canonicalCredentialJson({ OPENAI_API_KEY: "ferried" }))
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({ OPENAI_API_KEY: "ferried" })
    await source.applyDelete!()
    expect(await source.read()).toBeUndefined()
    // Deleting when already absent is a quiet no-op.
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

    // Verbatim apply onto a fresh machine, locked down to owner-only.
    const { home: other, byId: otherById } = await makeSources()
    const target = otherById["devin-credentials-file"]!
    await target.apply(content)
    const applied = join(other, ".local", "share", "devin", "credentials.toml")
    expect(await readFile(applied, "utf8")).toBe(content)
    expect(((await stat(applied)).mode & 0o777).toString(8)).toBe("600")

    // A fleet sign-out removes the file.
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

    // A directory where the file should be is an error, never "absent".
    const broken = await mkdtemp(join(tmpdir(), "codevisor-ferry-"))
    roots.push(broken)
    await mkdir(join(broken, ".local", "share", "devin", "credentials.toml"), {
      recursive: true
    })
    const brokenSource = credentialFerrySources({
      resolveEnv: () => Promise.resolve({ HOME: broken })
    }).find((candidate) => candidate.id === "devin-credentials-file")!
    await expect(brokenSource.read()).rejects.toThrow()

    // A bare environment falls back to the process home; the read itself
    // must be well-formed either way (present file or none).
    const bare = credentialFerrySources({ resolveEnv: () => Promise.resolve({}) }).find(
      (candidate) => candidate.id === "devin-credentials-file"
    )!
    const bareRead = await bare.read()
    expect(bareRead === undefined || typeof bareRead === "string").toBe(true)
  })
})

describe("hostile files and path variants", () => {
  it("rejects non-object files, surfaces read errors, and honors dir overrides", async () => {
    const home = await mkdtemp(join(tmpdir(), "codevisor-ferry-h-"))
    roots.push(home)

    // PI_CODING_AGENT_DIR with a ~ prefix expands against HOME; a custom
    // CODEX_HOME wins over the default.
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
    // Non-object entries are simply not part of the travelling class.
    expect(await byId["pi-auth"]!.read()).toBe(
      canonicalCredentialJson({ openai: { type: "api_key", key: "sk-custom" } })
    )
    // Applying twice exercises the lock file's already-exists path.
    await byId["pi-auth"]!.apply(canonicalCredentialJson({ a: { type: "api_key", key: "1" } }))
    await byId["pi-auth"]!.apply(canonicalCredentialJson({ a: { type: "api_key", key: "2" } }))

    await mkdir(join(home, "custom-codex"), { recursive: true })
    await writeFile(join(home, "custom-codex", "auth.json"), JSON.stringify(["an", "array"]))
    await expect(byId["codex-auth-file"]!.read()).rejects.toThrow("Not a credential object")

    // An unreadable file propagates its error rather than masking it.
    const { chmod } = await import("node:fs/promises")
    await chmod(join(home, "custom-codex", "auth.json"), 0o000)
    await expect(byId["codex-auth-file"]!.read()).rejects.toThrow()
    await chmod(join(home, "custom-codex", "auth.json"), 0o600)

    // An unwritable parent surfaces the real error from the lock setup.
    const lockedHome = await mkdtemp(join(tmpdir(), "codevisor-ferry-l-"))
    roots.push(lockedHome)
    const lockedDir = join(lockedHome, "custom-pi")
    await mkdir(lockedDir, { recursive: true })
    const { chmod: chmodDir } = await import("node:fs/promises")
    await chmodDir(lockedDir, 0o500)
    const locked = credentialFerrySources({
      resolveEnv: () => Promise.resolve({ HOME: lockedHome, PI_CODING_AGENT_DIR: lockedDir })
    }).find((source) => source.id === "pi-auth")!
    await expect(
      locked.apply(canonicalCredentialJson({ a: { type: "api_key", key: "x" } }))
    ).rejects.toThrow()
    await chmodDir(lockedDir, 0o700)

    // An empty override falls back to the default location.
    const emptied = credentialFerrySources({
      resolveEnv: () => Promise.resolve({ HOME: home, PI_CODING_AGENT_DIR: "", CODEX_HOME: "" })
    })
    expect(await emptied.find((source) => source.id === "pi-auth")!.read()).toBeUndefined()

    // Absent HOME falls back to the OS home for path computation only —
    // reads on the resulting paths must not throw.
    const bare = credentialFerrySources({
      resolveEnv: () => Promise.resolve({ PI_CODING_AGENT_DIR: "~/nowhere-pi" })
    })
    const pi = bare.find((source) => source.id === "pi-auth")!
    expect(await pi.read()).toBeUndefined()
    const codexBare = bare.find((source) => source.id === "codex-auth-file")!
    await codexBare.read().catch(() => undefined)
    // Fully empty env: the pi DEFAULT path also computes off the OS home.
    const emptyEnv = credentialFerrySources({ resolveEnv: () => Promise.resolve({}) })
    await emptyEnv
      .find((source) => source.id === "pi-auth")!
      .read()
      .catch(() => undefined)
  })
})
