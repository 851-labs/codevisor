import { existsSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import {
  assertSafeChild,
  copyDirectory,
  isPathSafe,
  parseFrontmatter,
  sanitizeName
} from "./skills-store.js"
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

describe("assertSafeChild", () => {
  it("returns direct children and rejects traversal or nested names", () => {
    expect(assertSafeChild("/store", "deploy")).toBe("/store/deploy")
    for (const name of ["", ".", "..", "a/b", "a\\b", "../x"]) {
      expect(() => assertSafeChild("/store", name)).toThrow("Invalid skill directory name")
    }
  })
})

describe("copyDirectory", () => {
  it("copies nested files, skips excluded entries, and skips broken links", async () => {
    const home = makeHome()
    const source = join(home, "source")
    writeSkill(source, { name: "Source" })
    mkdirSync(join(source, "refs/deep"), { recursive: true })
    writeFileSync(join(source, "refs/deep/notes.md"), "notes")
    writeFileSync(join(source, "metadata.json"), "{}")
    mkdirSync(join(source, ".git"))
    writeFileSync(join(source, ".git/HEAD"), "ref")
    symlinkSync(join(home, "missing"), join(source, "dangling"))
    await copyDirectory(source, join(home, "copy"))
    expect(readFileSync(join(home, "copy/refs/deep/notes.md"), "utf8")).toBe("notes")
    for (const skipped of ["metadata.json", ".git", "dangling"]) {
      expect(existsSync(join(home, "copy", skipped))).toBe(false)
    }
  })
})
