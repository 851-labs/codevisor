import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readlink,
  rm,
  stat,
  writeFile
} from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import {
  linkMuseConfigHome,
  museAuthPath,
  museProfileEnv,
  parseMuseAuth,
  removeMuseAuth,
  writeMuseAuth
} from "./muse-credentials.js"
import { readNativeOAuth } from "./shared-oauth-providers.js"

const directory = async () => {
  const path = await mkdtemp(join(tmpdir(), "muse-credentials-"))
  onTestFinished(() => rm(path, { recursive: true, force: true }))
  return path
}

const meta = {
  access_token: "access-1",
  obtained_via: "device_code",
  mechanism: "oauth",
  api_key: "LLM|1|key",
  api_base_url: "https://api.meta.ai/v1",
  subs_active: true,
  user_full_name: "Person",
  user_email: "Person@Example.com",
  user_avatar_url: "https://example.com/a.png"
}
const document = { schema_version: 1, providers: { meta } }

describe("Muse credentials", () => {
  it("turns a file-backend sign-in into a long-lived vault bundle keyed by the Meta account", () => {
    const bundle = parseMuseAuth(document, "managed")!
    expect(bundle).toMatchObject({
      harnessId: "muse-code",
      accessToken: "access-1",
      expiresAt: Number.MAX_SAFE_INTEGER,
      ownership: "managed",
      email: "Person@Example.com",
      credential: { meta }
    })
    expect(bundle).not.toHaveProperty("refreshToken")
    const again = parseMuseAuth(
      {
        providers: { meta: { ...meta, access_token: "access-2", user_email: "person@example.com" } }
      },
      "managed"
    )!
    expect(again.subject).toBe(bundle.subject)
    expect(bundle.subject).not.toContain("person")
    const keyOnly = parseMuseAuth({ providers: { meta: { api_key: "LLM|2|k" } } }, "external")!
    expect(keyOnly).toMatchObject({ accessToken: "LLM|2|k", ownership: "external" })
    expect(keyOnly).not.toHaveProperty("email")
    expect(
      parseMuseAuth({ providers: { meta: { mechanism: "oauth" } } }, "managed")
    ).toBeUndefined()
    expect(parseMuseAuth("not json", "managed")).toBeUndefined()
  })

  it("writes a shared sign-in back as Muse's own file, private to the user", async () => {
    const profile = await directory()
    await writeMuseAuth(profile, parseMuseAuth(document, "managed")!)
    const path = museAuthPath(profile)
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual(document)
    expect((await stat(path)).mode & 0o777).toBe(0o600)
    const captured = await readNativeOAuth({
      harnessId: "muse-code",
      directory: profile,
      isDefault: false,
      ownership: "managed",
      env: {},
      exec: async () => {
        throw new Error("Muse's file sign-in never touches the Keychain")
      }
    })
    expect(captured).toMatchObject({ accessToken: "access-1", credential: { meta } })
    const { credential: _credential, ...bare } = captured!
    await writeMuseAuth(profile, bare)
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({
      schema_version: 1,
      providers: { meta: {} }
    })
    await removeMuseAuth(profile)
    await removeMuseAuth(profile)
    await expect(stat(path)).rejects.toMatchObject({ code: "ENOENT" })
    expect(museProfileEnv(profile)).toEqual({
      XDG_CONFIG_HOME: join(profile, "config"),
      TBH_CREDENTIAL_BACKEND: "file"
    })
  })

  it("adopts nothing but an exported key from the user's own Muse", async () => {
    const home = await directory()
    const read = (env: NodeJS.ProcessEnv, isDefault = true) =>
      readNativeOAuth({
        harnessId: "muse-code",
        directory: home,
        isDefault,
        ownership: "external",
        env,
        exec: async () => ({ stdout: "", stderr: "" })
      })
    expect(await read({ META_API_KEY: "sk-env" })).toMatchObject({
      authMethod: "apiKey",
      accessToken: "sk-env"
    })
    expect(await read({})).toBeUndefined()
    expect(await read({ META_API_KEY: "sk-env" }, false)).toBeUndefined()
  })

  it("links the user's config into a managed home, keeping only the credential separate", async () => {
    const home = await directory()
    const own = join(home, ".config")
    await mkdir(join(own, "gh"), { recursive: true })
    await mkdir(join(own, "muse", "skills"), { recursive: true })
    await writeFile(join(own, "muse", "settings.json"), "{}")
    await writeFile(join(own, "muse", "auth.json"), "{}")
    await writeFile(join(own, "muse", ".settings.json.lock"), "")
    const profile = join(home, "profile")
    await mkdir(join(profile, "config", "muse"), { recursive: true })
    await writeFile(join(profile, "config", "muse", "trust.json"), "{}")
    await writeFile(join(own, "muse", "trust.json"), "{}")

    await linkMuseConfigHome(profile, { HOME: home })
    await linkMuseConfigHome(profile, { HOME: home })
    const managed = join(profile, "config")
    expect(await readlink(join(managed, "gh"))).toBe(join(own, "gh"))
    expect(await readlink(join(managed, "muse", "settings.json"))).toBe(
      join(own, "muse", "settings.json")
    )
    expect(await readlink(join(managed, "muse", "skills"))).toBe(join(own, "muse", "skills"))
    expect((await lstat(join(managed, "muse"))).isSymbolicLink()).toBe(false)
    expect((await lstat(join(managed, "muse", "trust.json"))).isSymbolicLink()).toBe(false)
    await expect(lstat(join(managed, "muse", "auth.json"))).rejects.toMatchObject({
      code: "ENOENT"
    })
    await expect(lstat(join(managed, "muse", ".settings.json.lock"))).rejects.toMatchObject({
      code: "ENOENT"
    })

    const elsewhere = join(home, "xdg")
    await mkdir(join(elsewhere, "git"), { recursive: true })
    await linkMuseConfigHome(join(home, "second"), { XDG_CONFIG_HOME: elsewhere })
    expect(await readlink(join(home, "second", "config", "git"))).toBe(join(elsewhere, "git"))
    await linkMuseConfigHome(join(home, "third"), { XDG_CONFIG_HOME: join(home, "missing") })
    expect((await stat(join(home, "third", "config", "muse"))).isDirectory()).toBe(true)
    await linkMuseConfigHome(join(home, "fourth"), {})
    expect((await stat(join(home, "fourth", "config", "muse"))).isDirectory()).toBe(true)
    const locked = join(home, "locked")
    await mkdir(join(locked, "config", "muse"), { recursive: true })
    await chmod(join(locked, "config"), 0o500)
    onTestFinished(() => chmod(join(locked, "config"), 0o700))
    await linkMuseConfigHome(locked, { HOME: home })
    expect(await readlink(join(locked, "config", "muse", "settings.json"))).toBe(
      join(own, "muse", "settings.json")
    )
    await expect(lstat(join(locked, "config", "gh"))).rejects.toMatchObject({ code: "ENOENT" })
  })
})
