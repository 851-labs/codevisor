import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { PLUGIN_AUTHORING_SKILL_DIRECTORY, pluginAuthoringSkill } from "./plugin-skill.js"

const roots: Array<string> = []

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { force: true, recursive: true })
  }
})

const makeRoot = (): string => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-plugin-skill-"))
  roots.push(root)
  return root
}

describe("pluginAuthoringSkill", () => {
  it("resolves the packaged skill from the module-relative resources tree", () => {
    const root = makeRoot()
    const skillDir = join(root, "resources", "skills", PLUGIN_AUTHORING_SKILL_DIRECTORY)
    mkdirSync(skillDir, { recursive: true })
    writeFileSync(join(skillDir, "SKILL.md"), "---\nname: create-codevisor-plugin\n---\n")
    const spec = pluginAuthoringSkill({
      moduleDirectory: join(root, "dist"),
      workingDirectory: join(root, "elsewhere")
    })
    expect(spec.name).toBe("create-codevisor-plugin")
    expect(spec.path).toBe(join(skillDir, "SKILL.md"))
  })

  it("falls back to the repo-root layout", () => {
    const root = makeRoot()
    const skillDir = join(
      root,
      "packages",
      "plugins",
      "resources",
      "skills",
      PLUGIN_AUTHORING_SKILL_DIRECTORY
    )
    mkdirSync(skillDir, { recursive: true })
    writeFileSync(join(skillDir, "SKILL.md"), "---\nname: create-codevisor-plugin\n---\n")
    const spec = pluginAuthoringSkill({
      moduleDirectory: join(root, "nowhere"),
      workingDirectory: root
    })
    expect(spec.path).toBe(join(skillDir, "SKILL.md"))
  })

  it("resolves the real packaged skill with default seams", () => {
    expect(pluginAuthoringSkill().path).toBe(
      join(
        import.meta.dirname,
        "..",
        "resources",
        "skills",
        PLUGIN_AUTHORING_SKILL_DIRECTORY,
        "SKILL.md"
      )
    )
  })

  it("throws when the packaged skill is missing", () => {
    const root = makeRoot()
    expect(() =>
      pluginAuthoringSkill({
        moduleDirectory: join(root, "dist"),
        workingDirectory: root
      })
    ).toThrow(/Missing packaged create-codevisor-plugin skill/)
  })
})
