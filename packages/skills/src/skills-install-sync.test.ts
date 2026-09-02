import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  symlinkSync,
  utimesSync,
  writeFileSync
} from "node:fs"
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

describe("managed skill synchronization across servers", () => {
  it("converges managed skills on the newest packaged source across servers", async () => {
    const home = makeHome()
    const older = join(home, "release-build/browser-use")
    const newer = join(home, "dev-build/browser-use")
    writeSkill(older, { body: "Release instructions.", name: "browser-use" })
    writeSkill(newer, { body: "Development instructions.", name: "browser-use" })
    const past = new Date(Date.now() - 60 * 60 * 1000)
    utimesSync(join(older, "SKILL.md"), past, past)
    const installed = join(home, ".agents/skills/browser-use")
    const skills = manager(home)

    await skills.syncManaged([{ directoryName: "browser-use", enabled: true, sourcePath: older }])
    expect(readFileSync(join(installed, "SKILL.md"), "utf8")).toContain("Release instructions.")

    // Re-syncing identical content is a no-op: files written alongside survive.
    writeFileSync(join(installed, "sentinel.txt"), "kept")
    await skills.syncManaged([{ directoryName: "browser-use", enabled: true, sourcePath: older }])
    expect(existsSync(join(installed, "sentinel.txt"))).toBe(true)

    // A newer build replaces the release copy (a dangling link in the source is tolerated)...
    symlinkSync(join(home, "missing-target"), join(newer, "dangling"))
    mkdirSync(join(newer, "references"))
    writeFileSync(join(newer, "references", "notes.md"), "Reference notes.")
    writeFileSync(join(newer, "metadata.json"), "{}")
    mkdirSync(join(newer, ".git"))
    writeFileSync(join(newer, ".git", "HEAD"), "ref: refs/heads/main")
    await skills.syncManaged([{ directoryName: "browser-use", enabled: true, sourcePath: newer }])
    expect(readFileSync(join(installed, "SKILL.md"), "utf8")).toContain("Development instructions.")
    expect(existsSync(join(installed, "sentinel.txt"))).toBe(false)

    // ...and the release build syncing afterwards leaves the newer copy alone.
    await skills.syncManaged([{ directoryName: "browser-use", enabled: true, sourcePath: older }])
    expect(readFileSync(join(installed, "SKILL.md"), "utf8")).toContain("Development instructions.")

    // Installs that predate the state file, or carry a corrupt one, are replaced.
    writeFileSync(join(installed, ".codevisor-managed-skill.json"), "{not json")
    await skills.syncManaged([{ directoryName: "browser-use", enabled: true, sourcePath: older }])
    expect(readFileSync(join(installed, "SKILL.md"), "utf8")).toContain("Release instructions.")
    writeFileSync(
      join(installed, ".codevisor-managed-skill.json"),
      JSON.stringify({ fingerprint: 1 })
    )
    await skills.syncManaged([{ directoryName: "browser-use", enabled: true, sourcePath: newer }])
    expect(readFileSync(join(installed, "SKILL.md"), "utf8")).toContain("Development instructions.")
    expect(
      JSON.parse(readFileSync(join(installed, ".codevisor-managed-skill.json"), "utf8"))
    ).toMatchObject({
      fingerprint: expect.any(String),
      sourceModifiedMs: expect.any(Number)
    })
  })
})
