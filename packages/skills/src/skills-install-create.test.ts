import { makeAgentRuntime } from "@codevisor/agent-runtime"
import { existsSync, lstatSync, mkdirSync, readFileSync, symlinkSync } from "node:fs"
import { join } from "node:path"
import { makeSkillsManager } from "./skills-manager.js"
import { afterEach, describe, expect, it } from "vitest"
import {
  cleanupSkillsTests,
  makeHome,
  writeSkill,
  manager,
  globalSkill,
  installState
} from "./skills-test-support.js"

afterEach(cleanupSkillsTests)

describe("create with pasted content", () => {
  it("writes frontmatter-bearing content verbatim and names the dir from it", async () => {
    const home = makeHome()
    const pasted = `---\nname: Deploy Checklist\ndescription: Steps for deploys\n---\n\n1. Ship it.`
    const scan = await manager(home).create({
      content: pasted,
      description: "ignored",
      name: "Whatever The Form Said"
    })
    const skill = globalSkill(scan, "deploy-checklist")
    expect(skill.name).toBe("Deploy Checklist")
    expect(skill.description).toBe("Steps for deploys")
    expect(readFileSync(join(home, ".agents/skills/deploy-checklist/SKILL.md"), "utf8")).toBe(
      `${pasted}\n`
    )
  })

  it("wraps plain pasted content in form-field frontmatter", async () => {
    const home = makeHome()
    const scan = await manager(home).create({
      content: "Just the body steps.",
      description: "A checklist",
      name: "deploy"
    })
    expect(globalSkill(scan, "deploy").description).toBe("A checklist")
    const raw = readFileSync(join(home, ".agents/skills/deploy/SKILL.md"), "utf8")
    expect(raw).toContain('name: "deploy"')
    expect(raw).toContain("Just the body steps.")
  })

  it("rejects pasted content with broken frontmatter", async () => {
    const home = makeHome()
    await expect(
      manager(home).create({ content: "---\n- broken\n---\n", description: "", name: "x" })
    ).rejects.toMatchObject({ code: "invalid" })
  })
})

describe("auto-install on create and import", () => {
  it("creating a skill links it into every link-based harness", async () => {
    const home = makeHome()
    const scan = await manager(home).create({ description: "Checklist", name: "deploy" })
    // Link-based harnesses get relative symlinks immediately.
    expect(lstatSync(join(home, ".claude/skills/deploy")).isSymbolicLink()).toBe(true)
    expect(lstatSync(join(home, ".codex/skills/deploy")).isSymbolicLink()).toBe(true)
    expect(installState(scan, "deploy", "claude-code")).toBe("linked")
    expect(installState(scan, "deploy", "codex")).toBe("linked")
    // Canonical readers need nothing on disk.
    expect(installState(scan, "deploy", "opencode")).toBe("canonical")
    expect(installState(scan, "deploy", "cline")).toBe("canonical")
    expect(existsSync(join(home, ".config/opencode/skills"))).toBe(false)
  })

  it("remote imports link every imported skill everywhere", async () => {
    const home = makeHome()
    const skills = makeSkillsManager({
      agents: makeAgentRuntime({}),
      env: {},
      homedir: home,
      overrides: {
        clone: async (_url, _ref, destination) => {
          writeSkill(join(destination, "skills/deploy"), { name: "Deploy" })
          writeSkill(join(destination, "skills/review"), { name: "Review" })
        }
      }
    })
    const scan = await skills.importRemote({ source: "o/r" })
    for (const name of ["deploy", "review"]) {
      expect(lstatSync(join(home, `.claude/skills/${name}`)).isSymbolicLink()).toBe(true)
      expect(installState(scan, name, "claude-code")).toBe("linked")
    }
  })

  it("skips conflicted harnesses without failing the creation", async () => {
    const home = makeHome()
    // A drifted skill with the same name already lives in Claude Code.
    writeSkill(join(home, ".claude/skills/deploy"), { body: "different", name: "Deploy" })
    const scan = await manager(home).create({ description: "", name: "deploy" })
    expect(globalSkill(scan, "deploy")).toBeDefined()
    expect(installState(scan, "deploy", "claude-code")).toBe("conflict")
    // Other harnesses still got their links.
    expect(installState(scan, "deploy", "codex")).toBe("linked")
    // The drifted copy is untouched.
    expect(readFileSync(join(home, ".claude/skills/deploy/SKILL.md"), "utf8")).toContain(
      "different"
    )
  })

  it("skips harness dirs the user symlinked onto the canonical store", async () => {
    const home = makeHome()
    mkdirSync(join(home, ".agents/skills"), { recursive: true })
    mkdirSync(join(home, ".codex"), { recursive: true })
    symlinkSync(join(home, ".agents/skills"), join(home, ".codex/skills"))
    const scan = await manager(home).create({ description: "", name: "deploy" })
    // No per-skill link inside the aliased dir — it would self-reference.
    expect(lstatSync(join(home, ".codex/skills")).isSymbolicLink()).toBe(true)
    expect(installState(scan, "deploy", "codex")).toBe("canonical")
  })

  it("local imports auto-install too", async () => {
    const home = makeHome()
    writeSkill(join(home, "src/deploy"), { name: "Deploy" })
    const scan = await manager(home).importLocal({ path: join(home, "src/deploy") })
    expect(installState(scan, "deploy", "claude-code")).toBe("linked")
  })
})
