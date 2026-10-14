import { chmod, lstat, mkdir, mkdtemp, readFile, readlink, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { antigravityGeminiDir, prepareAntigravityProfile } from "./antigravity-profile.js"

const roots: Array<string> = []

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })))
})

/// A user home with an agy config, and an empty managed profile beside it.
const fixture = async (settings?: string) => {
  const root = await mkdtemp(join(tmpdir(), "agy-profile-"))
  roots.push(root)
  const home = join(root, "home")
  const own = join(home, ".gemini")
  await mkdir(join(own, "config", "skills"), { recursive: true })
  await mkdir(join(own, "config", "projects"), { recursive: true })
  await mkdir(join(own, "antigravity-cli"), { recursive: true })
  await writeFile(join(own, "config", "mcp_config.json"), "{}")
  await writeFile(join(own, "config", "oauth_tokens.json"), "{}")
  await writeFile(join(own, "config", ".migrated"), "")
  await writeFile(join(own, "GEMINI.md"), "rules")
  await writeFile(join(own, "notes.txt"), "")
  if (settings !== undefined)
    await writeFile(join(own, "antigravity-cli", "settings.json"), settings)
  return { home, own, profile: join(root, "profile") }
}

const link = (path: string) => readlink(path).catch(() => undefined)
const exists = (path: string) =>
  lstat(path).then(
    () => true,
    () => false
  )

describe("managed Antigravity profiles", () => {
  it("links the user's agy config in around the account's own sign-in", async () => {
    const { home, own, profile } = await fixture('{"toolPermission":"always-proceed"}')
    const gemini = antigravityGeminiDir(profile)
    // Something the account already has stays its own.
    await mkdir(join(gemini, "config"), { recursive: true })
    await writeFile(join(gemini, "config", "mcp_config.json"), '{"mine":true}')

    expect(await prepareAntigravityProfile(profile, { HOME: home }, undefined)).toEqual({
      CODEVISOR_AGY_GEMINI_DIR: gemini
    })
    expect(await link(join(gemini, "config", "skills"))).toBe(join(own, "config", "skills"))
    expect(await readFile(join(gemini, "config", "mcp_config.json"), "utf8")).toBe('{"mine":true}')
    expect(await link(join(gemini, "GEMINI.md"))).toBe(join(own, "GEMINI.md"))
    expect(await link(join(gemini, "antigravity-cli", "settings.json"))).toBe(
      join(own, "antigravity-cli", "settings.json")
    )
    for (const unshared of [
      "config/projects",
      "config/oauth_tokens.json",
      "config/.migrated",
      "notes.txt"
    ])
      expect(await exists(join(gemini, unshared))).toBe(false)
  })

  it("gives an API-key account the user's settings with Gemini as the provider", async () => {
    const { home, profile } = await fixture('{"toolPermission":"always-proceed"}')
    await prepareAntigravityProfile(profile, { HOME: home }, undefined)
    expect(await prepareAntigravityProfile(profile, { HOME: home }, "AIza-1")).toEqual({
      CODEVISOR_AGY_GEMINI_DIR: antigravityGeminiDir(profile),
      GEMINI_API_KEY: "AIza-1"
    })
    const settings = join(antigravityGeminiDir(profile), "antigravity-cli", "settings.json")
    expect(await link(settings)).toBeUndefined()
    expect(JSON.parse(await readFile(settings, "utf8"))).toEqual({
      toolPermission: "always-proceed",
      modelProvider: "gemini"
    })
    // Without the key again, the account goes back to the user's settings.
    await prepareAntigravityProfile(profile, { HOME: home }, undefined)
    expect(await link(settings)).toBeDefined()
    await prepareAntigravityProfile(profile, { HOME: home }, undefined)
    expect(await link(settings)).toBeDefined()
  })

  it.each(["not json", "[1]"])("starts from empty settings when the user's are %j", async (bad) => {
    const { home, profile } = await fixture(bad)
    await prepareAntigravityProfile(profile, { HOME: home }, "k")
    const settings = join(antigravityGeminiDir(profile), "antigravity-cli", "settings.json")
    expect(JSON.parse(await readFile(settings, "utf8"))).toEqual({ modelProvider: "gemini" })
  })

  it("still starts when a link can't be made", async () => {
    const { home, profile } = await fixture("{}")
    const gemini = antigravityGeminiDir(profile)
    const locked = [join(gemini, "config"), join(gemini, "antigravity-cli")]
    for (const directory of locked) {
      await mkdir(directory, { recursive: true })
      await chmod(directory, 0o500)
    }
    try {
      await expect(prepareAntigravityProfile(profile, { HOME: home }, undefined)).resolves.toEqual({
        CODEVISOR_AGY_GEMINI_DIR: gemini
      })
      expect(await exists(join(gemini, "config", "skills"))).toBe(false)
      expect(await exists(join(gemini, "antigravity-cli", "settings.json"))).toBe(false)
    } finally {
      for (const directory of locked) await chmod(directory, 0o700)
    }
  })

  it("lays out a bare root when there's no user config to link", async () => {
    const { profile } = await fixture()
    const bare = await mkdtemp(join(tmpdir(), "agy-bare-"))
    roots.push(bare)
    await prepareAntigravityProfile(profile, { HOME: bare }, undefined)
    expect(
      await exists(join(antigravityGeminiDir(profile), "antigravity-cli", "settings.json"))
    ).toBe(false)
    await prepareAntigravityProfile(join(bare, "p"), {}, "k")
    expect(
      JSON.parse(
        await readFile(
          join(antigravityGeminiDir(join(bare, "p")), "antigravity-cli", "settings.json"),
          "utf8"
        )
      )
    ).toEqual({ modelProvider: "gemini" })
  })
})
