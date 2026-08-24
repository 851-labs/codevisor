import { execSync } from "node:child_process"
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, beforeEach, describe, expect, it } from "vitest"
import { treeHash } from "./tree-hash.js"

describe("treeHash", () => {
  let root: string

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "tree-hash-"))
  })

  afterEach(() => {
    rmSync(root, { recursive: true, force: true })
  })

  const makeSkill = (base: string): void => {
    mkdirSync(join(base, "references"), { recursive: true })
    writeFileSync(join(base, "SKILL.md"), "---\nname: demo\n---\nbody\n")
    writeFileSync(join(base, "references", "notes.md"), "notes\n")
    symlinkSync("SKILL.md", join(base, "alias.md"))
  }

  it("is identical for identical trees, regardless of timestamps", async () => {
    const a = join(root, "a")
    const b = join(root, "b")
    mkdirSync(a)
    mkdirSync(b)
    makeSkill(a)
    makeSkill(b)
    utimesSync(join(a, "SKILL.md"), new Date(0), new Date(0))

    expect(await treeHash(a)).toBe(await treeHash(b))
  })

  it("changes when contents, names, or symlink targets change", async () => {
    const base = join(root, "skill")
    mkdirSync(base)
    makeSkill(base)
    const before = await treeHash(base)

    writeFileSync(join(base, "SKILL.md"), "---\nname: demo\n---\nedited\n")
    const afterEdit = await treeHash(base)
    expect(afterEdit).not.toBe(before)

    writeFileSync(join(base, "extra.md"), "more\n")
    expect(await treeHash(base)).not.toBe(afterEdit)

    rmSync(join(base, "alias.md"))
    symlinkSync("extra.md", join(base, "alias.md"))
    expect(await treeHash(base)).not.toBe(afterEdit)
  })

  it("ignores unreplicable entries like fifos", async () => {
    const base = join(root, "skill")
    mkdirSync(base)
    makeSkill(base)
    const before = await treeHash(base)

    execSync(`mkfifo ${JSON.stringify(join(base, "pipe"))}`)
    expect(await treeHash(base)).toBe(before)
  })

  it("excludes the requested names", async () => {
    const base = join(root, "skill")
    mkdirSync(base)
    makeSkill(base)
    const clean = await treeHash(base, { exclude: new Set([".marker"]) })

    writeFileSync(join(base, ".marker"), "managed\n")
    expect(await treeHash(base, { exclude: new Set([".marker"]) })).toBe(clean)
    expect(await treeHash(base)).not.toBe(clean)
  })
})
