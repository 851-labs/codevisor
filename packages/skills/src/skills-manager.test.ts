import { makeAgentRuntime } from "@codevisor/agent-runtime"
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  symlinkSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { makeSkillsManager } from "./skills-manager.js"
import { afterEach, describe, expect, it } from "vitest"
import {
  cleanupSkillsTests,
  directories,
  makeHome,
  writeSkill,
  manager,
  globalSkill,
  group,
  installState
} from "./skills-test-support.js"

afterEach(cleanupSkillsTests)

describe("makeSkillsManager", () => {
  it("constructs with default home and env seams", () => {
    expect(makeSkillsManager({ agents: makeAgentRuntime({}) })).toBeDefined()
  })

  it("returns empty state when nothing exists", async () => {
    const home = makeHome()
    const scan = await manager(home).list()
    expect(scan.canonicalDir).toBe(join(home, ".agents/skills"))
    expect(scan.global).toEqual([])
    const ids = scan.harnesses.map((harness) => harness.harnessId)
    expect(ids).toContain("claude-code")
    expect(ids).toContain("cline")
    expect(ids).not.toContain("goose")
    for (const harness of scan.harnesses) expect(harness.skills).toEqual([])
  })

  it("installs app-managed skills everywhere without exposing them as user skills", async () => {
    const home = makeHome()
    const sources = join(home, "managed-sources")
    writeSkill(join(sources, "browser-use"), { name: "browser-use" })
    writeSkill(join(sources, "computer-use"), { name: "computer-use" })
    const skills = manager(home)

    await skills.syncManaged([
      {
        directoryName: "browser-use",
        enabled: true,
        sourcePath: join(sources, "browser-use")
      },
      {
        directoryName: "computer-use",
        enabled: true,
        sourcePath: join(sources, "computer-use")
      }
    ])

    const scan = await skills.list()
    expect(scan.global).toEqual([])
    expect(scan.harnesses.every((harness) => harness.skills.length === 0)).toBe(true)
    expect(existsSync(join(home, ".agents/skills/browser-use/SKILL.md"))).toBe(true)
    expect(existsSync(join(home, ".claude/skills/computer-use/SKILL.md"))).toBe(true)
    expect(existsSync(join(home, ".codex/skills/computer-use/SKILL.md"))).toBe(true)

    await skills.syncManaged([
      {
        directoryName: "browser-use",
        enabled: true,
        sourcePath: join(sources, "browser-use")
      },
      {
        directoryName: "computer-use",
        enabled: false,
        sourcePath: join(sources, "computer-use")
      }
    ])

    expect(existsSync(join(home, ".agents/skills/browser-use/SKILL.md"))).toBe(true)
    expect(existsSync(join(home, ".agents/skills/computer-use"))).toBe(false)
    expect(existsSync(join(home, ".claude/skills/computer-use"))).toBe(false)
    expect(existsSync(join(home, ".codex/skills/computer-use"))).toBe(false)
  })

  it("never overwrites a same-name user skill during managed synchronization", async () => {
    const home = makeHome()
    const userSkill = join(home, ".agents/skills/computer-use")
    const source = join(home, "managed-sources/computer-use")
    writeSkill(userSkill, { body: "User-owned instructions.", name: "computer-use" })
    writeSkill(source, { body: "Managed instructions.", name: "computer-use" })

    const skills = manager(home)
    await skills.syncManaged([{ directoryName: "computer-use", enabled: true, sourcePath: source }])

    expect(readFileSync(join(userSkill, "SKILL.md"), "utf8")).toContain("User-owned instructions.")
    expect(globalSkill(await skills.list(), "computer-use").name).toBe("computer-use")
  })

  it("lists canonical skills with frontmatter and per-harness install states", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), {
      description: "Deploy checklist",
      name: "Deploy"
    })
    const scan = await manager(home).list()
    expect(globalSkill(scan, "deploy")).toMatchObject({
      description: "Deploy checklist",
      name: "Deploy",
      path: join(home, ".agents/skills/deploy")
    })
    // cline reads the canonical store natively; others are not installed.
    expect(installState(scan, "deploy", "cline")).toBe("canonical")
    expect(installState(scan, "deploy", "claude-code")).toBe("notInstalled")
    expect(group(scan, "cline").skills).toEqual([])
  })

  it("classifies relative symlinks into the canonical store as linked", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    mkdirSync(join(home, ".claude/skills"), { recursive: true })
    symlinkSync("../../.agents/skills/deploy", join(home, ".claude/skills/deploy"))
    const scan = await manager(home).list()
    expect(installState(scan, "deploy", "claude-code")).toBe("linked")
    expect(group(scan, "claude-code").skills).toEqual([])
  })

  it("treats a harness dir symlinked to the canonical store as canonical", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    mkdirSync(join(home, ".codex"), { recursive: true })
    symlinkSync(join(home, ".agents/skills"), join(home, ".codex/skills"))
    const scan = await manager(home).list()
    expect(installState(scan, "deploy", "codex")).toBe("canonical")
    expect(group(scan, "codex").skills).toEqual([])
  })

  it("recognizes content-identical copies as copied installs", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    writeSkill(join(home, ".claude/skills/deploy"), { name: "Deploy" })
    const scan = await manager(home).list()
    expect(installState(scan, "deploy", "claude-code")).toBe("copied")
    expect(group(scan, "claude-code").skills).toEqual([])
  })

  it("flags same-name drifted copies as conflicts and lists them", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    writeSkill(join(home, ".claude/skills/deploy"), { body: "Different steps.", name: "Deploy" })
    const scan = await manager(home).list()
    expect(installState(scan, "deploy", "claude-code")).toBe("conflict")
    expect(group(scan, "claude-code").skills[0]).toMatchObject({
      classification: "independent",
      directoryName: "deploy"
    })
    expect(group(scan, "claude-code").skills[0]?.duplicateOf).toBeUndefined()
  })

  it("detects renamed duplicates via content hash", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    writeSkill(join(home, ".claude/skills/ship-it"), { name: "Deploy" })
    const scan = await manager(home).list()
    expect(group(scan, "claude-code").skills[0]).toMatchObject({
      directoryName: "ship-it",
      duplicateOf: "deploy"
    })
  })

  it("ignores excluded directories when hashing", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    writeSkill(join(home, ".claude/skills/deploy"), { name: "Deploy" })
    mkdirSync(join(home, ".claude/skills/deploy/.git"), { recursive: true })
    writeFileSync(join(home, ".claude/skills/deploy/.git/HEAD"), "ref: main")
    writeFileSync(join(home, ".claude/skills/deploy/metadata.json"), "{}")
    const scan = await manager(home).list()
    expect(installState(scan, "deploy", "claude-code")).toBe("copied")
  })

  it("classifies dangling and circular symlinks as broken", async () => {
    const home = makeHome()
    mkdirSync(join(home, ".claude/skills"), { recursive: true })
    symlinkSync(join(home, "nowhere"), join(home, ".claude/skills/dangling"))
    symlinkSync(join(home, ".claude/skills/loop"), join(home, ".claude/skills/loop"))
    const scan = await manager(home).list()
    expect(
      group(scan, "claude-code")
        .skills.map((skill) => ({ c: skill.classification, d: skill.directoryName }))
        .sort((a, b) => a.d.localeCompare(b.d))
    ).toEqual([
      { c: "broken", d: "dangling" },
      { c: "broken", d: "loop" }
    ])
  })

  it("classifies links to canonical entries that are not skills as broken", async () => {
    const home = makeHome()
    // Canonical dir exists (so realpath succeeds) but holds no SKILL.md.
    mkdirSync(join(home, ".agents/skills/husk"), { recursive: true })
    mkdirSync(join(home, ".claude/skills"), { recursive: true })
    symlinkSync(join(home, ".agents/skills/husk"), join(home, ".claude/skills/husk"))
    const scan = await manager(home).list()
    expect(group(scan, "claude-code").skills[0]).toMatchObject({
      classification: "broken",
      directoryName: "husk"
    })
  })

  it("lists symlinks to skill folders outside the canonical store as independent", async () => {
    const home = makeHome()
    writeSkill(join(home, "elsewhere/tricks"), { name: "Tricks" })
    mkdirSync(join(home, ".claude/skills"), { recursive: true })
    symlinkSync(join(home, "elsewhere/tricks"), join(home, ".claude/skills/tricks"))
    const scan = await manager(home).list()
    expect(group(scan, "claude-code").skills[0]).toMatchObject({
      classification: "independent",
      directoryName: "tricks",
      name: "Tricks"
    })
  })

  it("skips symlinks to non-skill locations", async () => {
    const home = makeHome()
    mkdirSync(join(home, "elsewhere/empty"), { recursive: true })
    mkdirSync(join(home, ".claude/skills"), { recursive: true })
    symlinkSync(join(home, "elsewhere/empty"), join(home, ".claude/skills/empty"))
    const scan = await manager(home).list()
    expect(group(scan, "claude-code").skills).toEqual([])
  })

  it("skips loose files and directories without SKILL.md", async () => {
    const home = makeHome()
    mkdirSync(join(home, ".agents/skills/not-a-skill"), { recursive: true })
    writeFileSync(join(home, ".agents/skills/README.md"), "hello")
    mkdirSync(join(home, ".claude/skills/also-not"), { recursive: true })
    writeFileSync(join(home, ".claude/skills/stray.txt"), "hello")
    const scan = await manager(home).list()
    expect(scan.global).toEqual([])
    expect(group(scan, "claude-code").skills).toEqual([])
  })

  it("follows canonical entries that are symlinks to skill directories", async () => {
    const home = makeHome()
    writeSkill(join(home, "elsewhere/deploy"), { name: "Deploy" })
    mkdirSync(join(home, ".agents/skills"), { recursive: true })
    symlinkSync(join(home, "elsewhere/deploy"), join(home, ".agents/skills/deploy"))
    const scan = await manager(home).list()
    expect(globalSkill(scan, "deploy").name).toBe("Deploy")
  })

  it("falls back to the directory name for missing or malformed frontmatter", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/plain"))
    mkdirSync(join(home, ".agents/skills/bad"), { recursive: true })
    writeFileSync(join(home, ".agents/skills/bad/SKILL.md"), "---\n- not\n- a-mapping\n---\n")
    const scan = await manager(home).list()
    expect(globalSkill(scan, "plain")).toMatchObject({ name: "plain" })
    expect(globalSkill(scan, "plain").invalid).toBeUndefined()
    expect(globalSkill(scan, "bad")).toMatchObject({ invalid: true, name: "bad" })
  })

  it("carries invalid and missing-description states for harness-dir skills", async () => {
    const home = makeHome()
    writeSkill(join(home, ".claude/skills/plain"))
    mkdirSync(join(home, ".claude/skills/bad"), { recursive: true })
    writeFileSync(join(home, ".claude/skills/bad/SKILL.md"), "---\n- not\n- a-mapping\n---\n")
    const scan = await manager(home).list()
    const skills = group(scan, "claude-code").skills
    expect(skills.find((skill) => skill.directoryName === "plain")).toMatchObject({
      classification: "independent",
      name: "plain"
    })
    expect(skills.find((skill) => skill.directoryName === "plain")?.description).toBeUndefined()
    expect(skills.find((skill) => skill.directoryName === "bad")).toMatchObject({
      invalid: true,
      name: "bad"
    })
  })

  it("honors XDG_CONFIG_HOME for harnesses under ~/.config", async () => {
    const home = makeHome()
    const xdg = mkdtempSync(join(tmpdir(), "codevisor-xdg-"))
    directories.push(xdg)
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    writeSkill(join(xdg, "opencode/skills/deploy"), { name: "Deploy" })
    const scan = await manager(home, { XDG_CONFIG_HOME: xdg }).list()
    expect(group(scan, "opencode").skillsDir).toBe(join(xdg, "opencode/skills"))
    expect(installState(scan, "deploy", "opencode")).toBe("copied")
  })

  it("tolerates a skills dir that is not a directory", async () => {
    const home = makeHome()
    mkdirSync(join(home, ".claude"), { recursive: true })
    writeFileSync(join(home, ".claude/skills"), "not a directory")
    const scan = await manager(home).list()
    expect(group(scan, "claude-code").skills).toEqual([])
  })
})
