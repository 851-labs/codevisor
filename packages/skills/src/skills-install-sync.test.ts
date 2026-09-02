import { existsSync, lstatSync, mkdirSync, readFileSync, symlinkSync } from "node:fs"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import {
  cleanupSkillsTests,
  makeHome,
  writeSkill,
  manager,
  globalSkill,
  group,
  installState
} from "./skills-test-support.js"

afterEach(cleanupSkillsTests)

describe("ambient canonical readers (alsoReadsCanonical)", () => {
  it("reports global skills as canonical for opencode without any link", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    const scan = await manager(home).list()
    expect(installState(scan, "deploy", "opencode")).toBe("canonical")
    expect(existsSync(join(home, ".config/opencode/skills"))).toBe(false)
  })

  it("still lists opencode's own independent skills", async () => {
    const home = makeHome()
    writeSkill(join(home, ".config/opencode/skills/local-trick"), { name: "Local Trick" })
    const scan = await manager(home).list()
    expect(group(scan, "opencode").skills[0]).toMatchObject({
      classification: "independent",
      directoryName: "local-trick"
    })
  })

  it("treats install as a no-op but still removes redundant links", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    const skills = manager(home)
    const installed = await skills.setInstalled("deploy", "opencode", true)
    expect(existsSync(join(home, ".config/opencode/skills/deploy"))).toBe(false)
    expect(installState(installed, "deploy", "opencode")).toBe("canonical")

    // A redundant link left behind by another tool can still be cleaned up.
    mkdirSync(join(home, ".config/opencode/skills"), { recursive: true })
    symlinkSync(join(home, ".agents/skills/deploy"), join(home, ".config/opencode/skills/deploy"))
    const removed = await skills.setInstalled("deploy", "opencode", false)
    expect(existsSync(join(home, ".config/opencode/skills/deploy"))).toBe(false)
    expect(installState(removed, "deploy", "opencode")).toBe("canonical")
  })

  it("makeGlobal from opencode moves the skill without linking back", async () => {
    const home = makeHome()
    writeSkill(join(home, ".config/opencode/skills/tricks"), { name: "Tricks" })
    const scan = await manager(home).makeGlobal("opencode", "tricks")
    expect(globalSkill(scan, "tricks")).toBeDefined()
    // No link back: the skill is ambiently visible via ~/.agents/skills.
    expect(existsSync(join(home, ".config/opencode/skills/tricks"))).toBe(false)
    expect(installState(scan, "tricks", "opencode")).toBe("canonical")
  })

  it("makeGlobal of an identical copy from opencode removes it without a link", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/tricks"), { name: "Tricks" })
    writeSkill(join(home, ".config/opencode/skills/tricks"), { name: "Tricks" })
    const scan = await manager(home).makeGlobal("opencode", "tricks")
    expect(existsSync(join(home, ".config/opencode/skills/tricks"))).toBe(false)
    expect(installState(scan, "tricks", "opencode")).toBe("canonical")
  })
})

describe("sync", () => {
  it("links every global skill into every link-based harness", async () => {
    const home = makeHome()
    // Pre-existing skills that were never linked anywhere (e.g. dropped into
    // the store by another tool).
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    writeSkill(join(home, ".agents/skills/review"), { name: "Review" })
    const scan = await manager(home).sync()
    for (const name of ["deploy", "review"]) {
      expect(installState(scan, name, "claude-code")).toBe("linked")
      expect(installState(scan, name, "codex")).toBe("linked")
      expect(installState(scan, name, "opencode")).toBe("canonical")
      expect(lstatSync(join(home, `.claude/skills/${name}`)).isSymbolicLink()).toBe(true)
    }
  })

  it("syncs only the requested skills when names are given", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    writeSkill(join(home, ".agents/skills/review"), { name: "Review" })
    const scan = await manager(home).sync({ directoryNames: ["deploy"] })
    expect(installState(scan, "deploy", "claude-code")).toBe("linked")
    expect(installState(scan, "review", "claude-code")).toBe("notInstalled")
  })

  it("leaves conflicting copies alone and reports them", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    writeSkill(join(home, ".claude/skills/deploy"), { body: "drifted", name: "Deploy" })
    const scan = await manager(home).sync()
    expect(installState(scan, "deploy", "claude-code")).toBe("conflict")
    expect(installState(scan, "deploy", "codex")).toBe("linked")
    expect(readFileSync(join(home, ".claude/skills/deploy/SKILL.md"), "utf8")).toContain("drifted")
  })

  it("rejects unknown skill names before touching anything", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    await expect(manager(home).sync({ directoryNames: ["ghost"] })).rejects.toMatchObject({
      code: "notFound"
    })
    expect(existsSync(join(home, ".claude/skills/deploy"))).toBe(false)
  })

  it("is a no-op on an empty store", async () => {
    const home = makeHome()
    const scan = await manager(home).sync()
    expect(scan.global).toEqual([])
  })
})
