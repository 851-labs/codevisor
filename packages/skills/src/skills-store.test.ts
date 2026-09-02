import { mkdirSync, symlinkSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import {
  isPathSafe,
  parseFrontmatter,
  resolveParentSymlinks,
  sanitizeName,
  skillContentHash
} from "./skills-manager.js"
import { afterEach, describe, expect, it } from "vitest"
import { cleanupSkillsTests, makeHome, writeSkill } from "./skills-test-support.js"

afterEach(cleanupSkillsTests)

describe("sanitizeName", () => {
  it("kebab-cases and strips traversal attempts", () => {
    expect(sanitizeName("../../etc/passwd")).toBe("etc-passwd")
    expect(sanitizeName("My Cool Skill!")).toBe("my-cool-skill")
    expect(sanitizeName("..")).toBe("unnamed-skill")
  })

  it("caps length at 255 characters", () => {
    expect(sanitizeName("a".repeat(300))).toHaveLength(255)
  })
})

describe("isPathSafe", () => {
  it("accepts the base itself and children", () => {
    expect(isPathSafe("/base", "/base")).toBe(true)
    expect(isPathSafe("/base", "/base/child")).toBe(true)
  })

  it("rejects siblings and prefix tricks", () => {
    expect(isPathSafe("/base", "/base-evil")).toBe(false)
    expect(isPathSafe("/base", "/base/../other")).toBe(false)
  })
})

describe("parseFrontmatter", () => {
  it("parses yaml frontmatter and returns the body", () => {
    const { content, data } = parseFrontmatter("---\nname: Deploy\n---\nBody here")
    expect(data).toEqual({ name: "Deploy" })
    expect(content).toBe("Body here")
  })

  it("returns the raw text when no frontmatter exists", () => {
    expect(parseFrontmatter("just text")).toEqual({ content: "just text", data: {} })
  })

  it("returns empty data for empty frontmatter", () => {
    expect(parseFrontmatter("---\nnull\n---\n").data).toEqual({})
  })

  it("rejects non-mapping frontmatter", () => {
    expect(() => parseFrontmatter("---\n- a\n- b\n---\n")).toThrow("frontmatter is not a mapping")
    expect(() => parseFrontmatter("---\nplain string\n---\n")).toThrow(
      "frontmatter is not a mapping"
    )
  })
})

describe("skillContentHash", () => {
  it("hashes directory trees deterministically", async () => {
    const home = makeHome()
    writeSkill(join(home, "a"), { name: "X" })
    writeSkill(join(home, "b"), { name: "X" })
    mkdirSync(join(home, "a/refs"), { recursive: true })
    mkdirSync(join(home, "b/refs"), { recursive: true })
    writeFileSync(join(home, "a/refs/notes.md"), "notes")
    writeFileSync(join(home, "b/refs/notes.md"), "notes")
    expect(await skillContentHash(join(home, "a"))).toBe(await skillContentHash(join(home, "b")))
  })

  it("changes when contents differ", async () => {
    const home = makeHome()
    writeSkill(join(home, "a"), { name: "X" })
    writeSkill(join(home, "b"), { name: "Y" })
    expect(await skillContentHash(join(home, "a"))).not.toBe(
      await skillContentHash(join(home, "b"))
    )
  })

  it("folds unreadable entries into the hash without contents", async () => {
    const home = makeHome()
    writeSkill(join(home, "a"), { name: "X" })
    symlinkSync(join(home, "missing"), join(home, "a/dangling"))
    writeSkill(join(home, "b"), { name: "X" })
    expect(await skillContentHash(join(home, "a"))).not.toBe(
      await skillContentHash(join(home, "b"))
    )
  })
})

describe("resolveParentSymlinks", () => {
  it("resolves through a symlinked parent", async () => {
    const home = makeHome()
    mkdirSync(join(home, "real"), { recursive: true })
    symlinkSync(join(home, "real"), join(home, "alias"))
    const resolved = await resolveParentSymlinks(join(home, "alias/child"))
    // macOS tempdirs live under /private; compare suffixes.
    expect(resolved.endsWith("/real/child")).toBe(true)
  })

  it("returns the input when the parent does not exist", async () => {
    expect(await resolveParentSymlinks("/nope/child")).toBe("/nope/child")
  })
})
