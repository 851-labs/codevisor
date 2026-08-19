import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { managedPluginSkill, PLUGIN_AUTHORING_SKILL_DIRECTORY } from "./plugin-skill.js"

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

describe("managedPluginSkill", () => {
  it("resolves the packaged skill from the module-relative resources tree", () => {
    const root = makeRoot()
    const skillDir = join(root, "resources", "skills", PLUGIN_AUTHORING_SKILL_DIRECTORY)
    mkdirSync(skillDir, { recursive: true })
    writeFileSync(join(skillDir, "SKILL.md"), "---\nname: create-codevisor-plugin\n---\n")
    const spec = managedPluginSkill(true, {
      moduleDirectory: join(root, "dist"),
      workingDirectory: join(root, "elsewhere")
    })
    expect(spec.directoryName).toBe(PLUGIN_AUTHORING_SKILL_DIRECTORY)
    expect(spec.enabled).toBe(true)
    expect(spec.sourcePath).toBe(skillDir)
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
    const spec = managedPluginSkill(true, {
      moduleDirectory: join(root, "nowhere"),
      workingDirectory: root
    })
    expect(spec.sourcePath).toBe(skillDir)
  })

  it("resolves the real packaged skill with default seams", () => {
    // The repo layout satisfies the cwd fallback when tests run from the
    // package directory (moduleDirectory default points at src/).
    const spec = managedPluginSkill(true, { workingDirectory: join(process.cwd(), "..", "..") })
    expect(spec.sourcePath.endsWith(PLUGIN_AUTHORING_SKILL_DIRECTORY)).toBe(true)
  })

  it("defaults the working directory to the process cwd", () => {
    const spec = managedPluginSkill(true, { moduleDirectory: join(process.cwd(), "src") })
    expect(spec.sourcePath.endsWith(PLUGIN_AUTHORING_SKILL_DIRECTORY)).toBe(true)
  })

  it("throws a typed error when the packaged skill is missing", () => {
    const root = makeRoot()
    expect(() =>
      managedPluginSkill(true, {
        moduleDirectory: join(root, "dist"),
        workingDirectory: root
      })
    ).toThrow(/Missing packaged create-codevisor-plugin skill/)
  })

  it("carries no source path when disabled", () => {
    const spec = managedPluginSkill(false)
    expect(spec).toEqual({
      directoryName: PLUGIN_AUTHORING_SKILL_DIRECTORY,
      enabled: false,
      sourcePath: ""
    })
  })
})
