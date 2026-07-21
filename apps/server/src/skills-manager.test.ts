import { makeAgentRuntime } from "@codevisor/agent-runtime"
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  rmSync,
  symlinkSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { execSync } from "node:child_process"
import {
  isPathSafe,
  makeSkillsManager,
  parseFrontmatter,
  parseSkillSource,
  resolveParentSymlinks,
  sanitizeName,
  skillContentHash,
  SkillsError,
  type SkillsManager
} from "./skills-manager.js"

const directories: string[] = []

afterEach(() => {
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

const makeHome = (): string => {
  const home = mkdtempSync(join(tmpdir(), "codevisor-skills-"))
  directories.push(home)
  return home
}

const writeSkill = (
  dir: string,
  options: { readonly name?: string; readonly description?: string; readonly body?: string } = {}
): void => {
  mkdirSync(dir, { recursive: true })
  const frontmatter =
    options.name === undefined
      ? ""
      : `---\nname: ${options.name}\ndescription: ${options.description ?? "A test skill"}\n---\n`
  writeFileSync(join(dir, "SKILL.md"), `${frontmatter}${options.body ?? "Do the thing."}\n`)
}

const manager = (home: string, env: Record<string, string | undefined> = {}): SkillsManager =>
  makeSkillsManager({ agents: makeAgentRuntime({}), env, homedir: home })

const globalSkill = (scan: Awaited<ReturnType<SkillsManager["list"]>>, directoryName: string) => {
  const skill = scan.global.find((candidate) => candidate.directoryName === directoryName)
  if (skill === undefined) throw new Error(`missing global skill ${directoryName}`)
  return skill
}

const group = (scan: Awaited<ReturnType<SkillsManager["list"]>>, harnessId: string) => {
  const found = scan.harnesses.find((candidate) => candidate.harnessId === harnessId)
  if (found === undefined) throw new Error(`missing harness group ${harnessId}`)
  return found
}

const installState = (
  scan: Awaited<ReturnType<SkillsManager["list"]>>,
  directoryName: string,
  harnessId: string
): string | undefined =>
  globalSkill(scan, directoryName).installs.find((install) => install.harnessId === harnessId)
    ?.state

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

describe("skills write operations", () => {
  const managerWith = (
    home: string,
    overrides?: { symlink?: never; rename?: never } | Record<string, unknown>
  ): SkillsManager =>
    makeSkillsManager({
      agents: makeAgentRuntime({}),
      env: {},
      homedir: home,
      ...(overrides === undefined ? {} : { overrides })
    })

  describe("create", () => {
    it("creates a templated skill in the canonical store", async () => {
      const home = makeHome()
      const scan = await manager(home).create({
        description: "Deploy checklist",
        name: "My Deploy Steps!"
      })
      const skill = globalSkill(scan, "my-deploy-steps")
      expect(skill.name).toBe("My Deploy Steps!")
      expect(skill.description).toBe("Deploy checklist")
      const raw = readFileSync(join(home, ".agents/skills/my-deploy-steps/SKILL.md"), "utf8")
      expect(raw).toContain('name: "My Deploy Steps!"')
      expect(raw).toContain("## Instructions")
    })

    it("defaults an empty description to the name", async () => {
      const home = makeHome()
      const scan = await manager(home).create({ description: "  ", name: "deploy" })
      expect(globalSkill(scan, "deploy").description).toBe("deploy")
    })

    it("rejects empty names and duplicates", async () => {
      const home = makeHome()
      const skills = manager(home)
      await expect(skills.create({ description: "", name: "  " })).rejects.toMatchObject({
        code: "invalid"
      })
      await skills.create({ description: "", name: "deploy" })
      await expect(skills.create({ description: "", name: "Deploy" })).rejects.toMatchObject({
        code: "conflict"
      })
    })
  })

  describe("importLocal", () => {
    it("copies a skill folder into the canonical store, skipping excluded entries", async () => {
      const home = makeHome()
      writeSkill(join(home, "src/deploy"), { description: "Deploy checklist", name: "Deploy" })
      mkdirSync(join(home, "src/deploy/refs"), { recursive: true })
      writeFileSync(join(home, "src/deploy/refs/notes.md"), "notes")
      mkdirSync(join(home, "src/deploy/.git"), { recursive: true })
      writeFileSync(join(home, "src/deploy/.git/HEAD"), "ref: main")
      writeFileSync(join(home, "src/deploy/metadata.json"), "{}")
      const scan = await manager(home).importLocal({ path: join(home, "src/deploy") })
      expect(globalSkill(scan, "deploy").name).toBe("Deploy")
      expect(readFileSync(join(home, ".agents/skills/deploy/refs/notes.md"), "utf8")).toBe("notes")
      expect(existsSync(join(home, ".agents/skills/deploy/.git"))).toBe(false)
      expect(existsSync(join(home, ".agents/skills/deploy/metadata.json"))).toBe(false)
    })

    it("skips broken symlinks inside imported skills", async () => {
      const home = makeHome()
      writeSkill(join(home, "src/deploy"), { name: "Deploy" })
      symlinkSync(join(home, "src/missing-target"), join(home, "src/deploy/dangling"))
      const scan = await manager(home).importLocal({ path: join(home, "src/deploy") })
      expect(globalSkill(scan, "deploy")).toBeDefined()
      expect(existsSync(join(home, ".agents/skills/deploy/SKILL.md"))).toBe(true)
      expect(existsSync(join(home, ".agents/skills/deploy/dangling"))).toBe(false)
    })

    it("names the import from the folder when frontmatter is unusable", async () => {
      const home = makeHome()
      mkdirSync(join(home, "src/mystery"), { recursive: true })
      writeFileSync(join(home, "src/mystery/SKILL.md"), "---\n- broken\n---\n")
      const scan = await manager(home).importLocal({ path: join(home, "src/mystery") })
      expect(globalSkill(scan, "mystery").directoryName).toBe("mystery")
    })

    it("rejects non-directories and folders without SKILL.md", async () => {
      const home = makeHome()
      writeFileSync(join(home, "file.txt"), "hi")
      mkdirSync(join(home, "empty"), { recursive: true })
      const skills = manager(home)
      await expect(skills.importLocal({ path: join(home, "file.txt") })).rejects.toMatchObject({
        code: "invalid"
      })
      await expect(skills.importLocal({ path: join(home, "empty") })).rejects.toMatchObject({
        code: "invalid"
      })
    })

    it("treats importing a canonical skill onto itself as a no-op", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "deploy" })
      const scan = await manager(home).importLocal({ path: join(home, ".agents/skills/deploy") })
      expect(globalSkill(scan, "deploy")).toBeDefined()
    })

    it("refuses to overwrite an existing skill", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "deploy" })
      writeSkill(join(home, "src/deploy"), { body: "other", name: "deploy" })
      await expect(
        manager(home).importLocal({ path: join(home, "src/deploy") })
      ).rejects.toMatchObject({ code: "conflict" })
    })
  })

  describe("setInstalled", () => {
    it("installs via a relative symlink and uninstalls by removing only the link", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      const skills = manager(home)
      const installed = await skills.setInstalled("deploy", "claude-code", true)
      expect(installState(installed, "deploy", "claude-code")).toBe("linked")
      const linkPath = join(home, ".claude/skills/deploy")
      const stats = lstatSync(linkPath)
      expect(stats.isSymbolicLink()).toBe(true)
      expect(readlinkSync(linkPath).startsWith("/")).toBe(false)

      // Idempotent: installing again is a no-op, not an error.
      await skills.setInstalled("deploy", "claude-code", true)

      const removed = await skills.setInstalled("deploy", "claude-code", false)
      expect(installState(removed, "deploy", "claude-code")).toBe("notInstalled")
      expect(existsSync(linkPath)).toBe(false)
      // The canonical copy is untouched.
      expect(existsSync(join(home, ".agents/skills/deploy/SKILL.md"))).toBe(true)
    })

    it("is a no-op for harnesses that read the canonical store", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      const scan = await manager(home).setInstalled("deploy", "cline", true)
      expect(installState(scan, "deploy", "cline")).toBe("canonical")
      expect(existsSync(join(home, ".agents/skills/skills"))).toBe(false)
    })

    it("is a no-op when the harness dir is user-symlinked to the canonical store", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      mkdirSync(join(home, ".codex"), { recursive: true })
      symlinkSync(join(home, ".agents/skills"), join(home, ".codex/skills"))
      const scan = await manager(home).setInstalled("deploy", "codex", true)
      expect(installState(scan, "deploy", "codex")).toBe("canonical")
      expect(lstatSync(join(home, ".codex/skills")).isSymbolicLink()).toBe(true)
    })

    it("rejects unknown skills, harnesses, and traversal names", async () => {
      const home = makeHome()
      const skills = manager(home)
      await expect(skills.setInstalled("ghost", "claude-code", true)).rejects.toMatchObject({
        code: "notFound"
      })
      await expect(skills.setInstalled("deploy", "not-a-harness", true)).rejects.toMatchObject({
        code: "notFound"
      })
      await expect(skills.setInstalled("../evil", "claude-code", true)).rejects.toMatchObject({
        code: "invalid"
      })
    })

    it("treats an identical existing copy as installed and refuses drifted ones", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      writeSkill(join(home, ".claude/skills/deploy"), { name: "Deploy" })
      const skills = manager(home)
      const scan = await skills.setInstalled("deploy", "claude-code", true)
      expect(installState(scan, "deploy", "claude-code")).toBe("copied")

      writeFileSync(join(home, ".claude/skills/deploy/SKILL.md"), "drifted")
      await expect(skills.setInstalled("deploy", "claude-code", true)).rejects.toMatchObject({
        code: "conflict"
      })
      // REGRESSION (divergence from installer.ts): the drifted copy survives.
      expect(readFileSync(join(home, ".claude/skills/deploy/SKILL.md"), "utf8")).toBe("drifted")
    })

    it("repairs circular links during install", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      mkdirSync(join(home, ".claude/skills"), { recursive: true })
      symlinkSync(join(home, ".claude/skills/deploy"), join(home, ".claude/skills/deploy"))
      const scan = await manager(home).setInstalled("deploy", "claude-code", true)
      expect(installState(scan, "deploy", "claude-code")).toBe("linked")
    })

    it("replaces a link pointing at a different target", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      writeSkill(join(home, "elsewhere/deploy"), { name: "Deploy" })
      mkdirSync(join(home, ".claude/skills"), { recursive: true })
      symlinkSync(join(home, "elsewhere/deploy"), join(home, ".claude/skills/deploy"))
      const scan = await manager(home).setInstalled("deploy", "claude-code", true)
      expect(installState(scan, "deploy", "claude-code")).toBe("linked")
      expect(readlinkSync(join(home, ".claude/skills/deploy")).startsWith("/")).toBe(false)
    })

    it("falls back to copying when symlink creation fails", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      const skills = managerWith(home, {
        symlink: async () => {
          throw new Error("EPERM: symlinks unsupported")
        }
      })
      const scan = await skills.setInstalled("deploy", "claude-code", true)
      expect(installState(scan, "deploy", "claude-code")).toBe("copied")
      expect(lstatSync(join(home, ".claude/skills/deploy")).isDirectory()).toBe(true)
    })

    it("uninstall refuses links that point outside the canonical store", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      writeSkill(join(home, "elsewhere/deploy"), { name: "Other" })
      mkdirSync(join(home, ".claude/skills"), { recursive: true })
      symlinkSync(join(home, "elsewhere/deploy"), join(home, ".claude/skills/deploy"))
      await expect(
        manager(home).setInstalled("deploy", "claude-code", false)
      ).rejects.toMatchObject({ code: "conflict" })
      expect(existsSync(join(home, "elsewhere/deploy/SKILL.md"))).toBe(true)
    })

    it("uninstall removes hash-verified copies and refuses modified ones", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      writeSkill(join(home, ".claude/skills/deploy"), { name: "Deploy" })
      const skills = manager(home)
      const removed = await skills.setInstalled("deploy", "claude-code", false)
      expect(installState(removed, "deploy", "claude-code")).toBe("notInstalled")

      writeSkill(join(home, ".claude/skills/deploy"), { body: "edited", name: "Deploy" })
      await expect(skills.setInstalled("deploy", "claude-code", false)).rejects.toMatchObject({
        code: "conflict"
      })
      expect(existsSync(join(home, ".claude/skills/deploy/SKILL.md"))).toBe(true)
    })

    it("uninstall tolerates missing entries and removes stray files", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      const skills = manager(home)
      await skills.setInstalled("deploy", "claude-code", false)
      mkdirSync(join(home, ".claude/skills"), { recursive: true })
      writeFileSync(join(home, ".claude/skills/deploy"), "a stray file")
      await skills.setInstalled("deploy", "claude-code", false)
      expect(existsSync(join(home, ".claude/skills/deploy"))).toBe(false)
    })
  })

  describe("remove", () => {
    it("deletes the canonical skill and sweeps dangling links from harness dirs", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      writeSkill(join(home, ".agents/skills/other"), { name: "Other" })
      const skills = manager(home)
      await skills.setInstalled("deploy", "claude-code", true)
      await skills.setInstalled("other", "claude-code", true)
      // An unrelated link and a real directory must survive the sweep.
      writeSkill(join(home, "elsewhere/tricks"), { name: "Tricks" })
      symlinkSync(join(home, "elsewhere/tricks"), join(home, ".claude/skills/tricks"))
      writeSkill(join(home, ".claude/skills/local-copy"), { name: "Local" })

      const scan = await skills.remove("deploy")
      expect(scan.global.map((skill) => skill.directoryName)).toEqual(["other"])
      expect(existsSync(join(home, ".agents/skills/deploy"))).toBe(false)
      expect(existsSync(join(home, ".claude/skills/deploy"))).toBe(false)
      expect(existsSync(join(home, ".claude/skills/other/SKILL.md"))).toBe(true)
      expect(lstatSync(join(home, ".claude/skills/tricks")).isSymbolicLink()).toBe(true)
    })

    it("rejects unknown and unsafe names", async () => {
      const home = makeHome()
      const skills = manager(home)
      await expect(skills.remove("ghost")).rejects.toMatchObject({ code: "notFound" })
      await expect(skills.remove("../evil")).rejects.toMatchObject({ code: "invalid" })
      await expect(skills.remove("a/b")).rejects.toMatchObject({ code: "invalid" })
    })

    it("removes a canonical entry that is a symlink without touching its target", async () => {
      const home = makeHome()
      writeSkill(join(home, "elsewhere/deploy"), { name: "Deploy" })
      mkdirSync(join(home, ".agents/skills"), { recursive: true })
      symlinkSync(join(home, "elsewhere/deploy"), join(home, ".agents/skills/deploy"))
      await manager(home).remove("deploy")
      expect(existsSync(join(home, ".agents/skills/deploy"))).toBe(false)
      // The link's target survives — only the link was removed.
      expect(existsSync(join(home, "elsewhere/deploy/SKILL.md"))).toBe(true)
    })
  })

  describe("makeGlobal", () => {
    it("moves an independent skill into the canonical store and links it back", async () => {
      const home = makeHome()
      writeSkill(join(home, ".claude/skills/deploy"), { description: "Checklist", name: "Deploy" })
      const scan = await manager(home).makeGlobal("claude-code", "deploy")
      expect(globalSkill(scan, "deploy").description).toBe("Checklist")
      expect(installState(scan, "deploy", "claude-code")).toBe("linked")
      expect(lstatSync(join(home, ".claude/skills/deploy")).isSymbolicLink()).toBe(true)
      expect(existsSync(join(home, ".agents/skills/deploy/SKILL.md"))).toBe(true)
    })

    it("replaces an identical-content copy with a link to the existing global skill", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      writeSkill(join(home, ".claude/skills/deploy"), { name: "Deploy" })
      const scan = await manager(home).makeGlobal("claude-code", "deploy")
      expect(installState(scan, "deploy", "claude-code")).toBe("linked")
      expect(lstatSync(join(home, ".claude/skills/deploy")).isSymbolicLink()).toBe(true)
    })

    it("restores a copy when replacing an identical copy and linking fails", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      writeSkill(join(home, ".claude/skills/deploy"), { name: "Deploy" })
      const skills = managerWith(home, {
        symlink: async () => {
          throw new Error("EPERM: symlinks unsupported")
        }
      })
      const scan = await skills.makeGlobal("claude-code", "deploy")
      expect(installState(scan, "deploy", "claude-code")).toBe("copied")
      expect(lstatSync(join(home, ".claude/skills/deploy")).isDirectory()).toBe(true)
    })

    it("refuses to promote through a harness dir symlinked onto the canonical store", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      mkdirSync(join(home, ".codex"), { recursive: true })
      symlinkSync(join(home, ".agents/skills"), join(home, ".codex/skills"))
      // Promoting "through" the symlinked dir would otherwise delete the
      // canonical skill via its aliased parent.
      await expect(manager(home).makeGlobal("codex", "deploy")).rejects.toMatchObject({
        code: "invalid"
      })
      expect(existsSync(join(home, ".agents/skills/deploy/SKILL.md"))).toBe(true)
    })

    it("refuses when a different global skill owns the name", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      writeSkill(join(home, ".claude/skills/deploy"), { body: "different", name: "Deploy" })
      await expect(manager(home).makeGlobal("claude-code", "deploy")).rejects.toMatchObject({
        code: "conflict"
      })
      // Nothing was deleted.
      expect(readFileSync(join(home, ".claude/skills/deploy/SKILL.md"), "utf8")).toContain(
        "different"
      )
    })

    it("rejects links, non-skills, missing entries, and canonical-reading harnesses", async () => {
      const home = makeHome()
      writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
      const skills = manager(home)
      await skills.setInstalled("deploy", "claude-code", true)
      await expect(skills.makeGlobal("claude-code", "deploy")).rejects.toMatchObject({
        code: "invalid"
      })
      mkdirSync(join(home, ".claude/skills/not-a-skill"), { recursive: true })
      await expect(skills.makeGlobal("claude-code", "not-a-skill")).rejects.toMatchObject({
        code: "invalid"
      })
      await expect(skills.makeGlobal("claude-code", "ghost")).rejects.toMatchObject({
        code: "notFound"
      })
      await expect(skills.makeGlobal("cline", "anything")).rejects.toMatchObject({
        code: "invalid"
      })
    })

    it("falls back to copy-verify-remove on cross-device renames", async () => {
      const home = makeHome()
      writeSkill(join(home, ".claude/skills/deploy"), { name: "Deploy" })
      const skills = managerWith(home, {
        rename: async () => {
          const error = new Error("EXDEV: cross-device link") as NodeJS.ErrnoException
          error.code = "EXDEV"
          throw error
        }
      })
      const scan = await skills.makeGlobal("claude-code", "deploy")
      expect(installState(scan, "deploy", "claude-code")).toBe("linked")
      expect(existsSync(join(home, ".agents/skills/deploy/SKILL.md"))).toBe(true)
    })

    it("propagates non-EXDEV rename failures", async () => {
      const home = makeHome()
      writeSkill(join(home, ".claude/skills/deploy"), { name: "Deploy" })
      const skills = managerWith(home, {
        rename: async () => {
          throw new Error("EACCES: permission denied")
        }
      })
      await expect(skills.makeGlobal("claude-code", "deploy")).rejects.toThrow("EACCES")
    })

    it("degrades to a copy when the link back cannot be created", async () => {
      const home = makeHome()
      writeSkill(join(home, ".claude/skills/deploy"), { name: "Deploy" })
      const skills = managerWith(home, {
        symlink: async () => {
          throw new Error("EPERM: symlinks unsupported")
        }
      })
      const scan = await skills.makeGlobal("claude-code", "deploy")
      expect(installState(scan, "deploy", "claude-code")).toBe("copied")
      expect(lstatSync(join(home, ".claude/skills/deploy")).isDirectory()).toBe(true)
      expect(existsSync(join(home, ".agents/skills/deploy/SKILL.md"))).toBe(true)
    })
  })
})

describe("parseSkillSource", () => {
  it("parses owner/repo shorthand with refs and subpaths", () => {
    expect(parseSkillSource("vercel-labs/skills")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://github.com/vercel-labs/skills.git"
    })
    expect(parseSkillSource("vercel-labs/skills#main")).toEqual({
      kind: "git",
      ref: "main",
      url: "https://github.com/vercel-labs/skills.git"
    })
    expect(parseSkillSource("vercel-labs/skills/skills/find-skills")).toEqual({
      kind: "git",
      ref: undefined,
      subpath: "skills/find-skills",
      url: "https://github.com/vercel-labs/skills.git"
    })
    expect(parseSkillSource("github:vercel-labs/skills")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://github.com/vercel-labs/skills.git"
    })
  })

  it("parses github.com URLs including tree paths", () => {
    expect(parseSkillSource("https://github.com/vercel-labs/skills")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://github.com/vercel-labs/skills.git"
    })
    expect(parseSkillSource("https://github.com/vercel-labs/skills.git")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://github.com/vercel-labs/skills.git"
    })
    expect(
      parseSkillSource("https://github.com/vercel-labs/skills/tree/main/skills/find-skills")
    ).toEqual({
      kind: "git",
      ref: "main",
      subpath: "skills/find-skills",
      url: "https://github.com/vercel-labs/skills.git"
    })
    // An explicit #ref wins over the /tree/ segment.
    expect(parseSkillSource("https://github.com/o/r/tree/main/path#pinned")).toEqual({
      kind: "git",
      ref: "pinned",
      subpath: "path",
      url: "https://github.com/o/r.git"
    })
    // A tree URL for the repo root has a ref but no subpath.
    expect(parseSkillSource("https://github.com/o/r/tree/main")).toEqual({
      kind: "git",
      ref: "main",
      url: "https://github.com/o/r.git"
    })
    expect(parseSkillSource("https://github.com/o/r/some/path")).toEqual({
      kind: "git",
      ref: undefined,
      subpath: "some/path",
      url: "https://github.com/o/r.git"
    })
  })

  it("passes through local filesystem paths", () => {
    expect(parseSkillSource("/tmp/my-skills-repo")).toEqual({
      kind: "git",
      ref: undefined,
      url: "/tmp/my-skills-repo"
    })
    expect(parseSkillSource("./relative/repo")).toEqual({
      kind: "git",
      ref: undefined,
      url: "./relative/repo"
    })
    expect(parseSkillSource("../up/repo")).toEqual({
      kind: "git",
      ref: undefined,
      url: "../up/repo"
    })
    expect(parseSkillSource("/tmp/repo#main")).toEqual({
      kind: "git",
      ref: "main",
      url: "/tmp/repo"
    })
  })

  it("passes through git and non-GitHub URLs", () => {
    expect(parseSkillSource("git@github.com:o/r.git")).toEqual({
      kind: "git",
      ref: undefined,
      url: "git@github.com:o/r.git"
    })
    expect(parseSkillSource("ssh://git@host/o/r.git#v2")).toEqual({
      kind: "git",
      ref: "v2",
      url: "ssh://git@host/o/r.git"
    })
    expect(parseSkillSource("https://gitlab.com/o/r.git#dev")).toEqual({
      kind: "git",
      ref: "dev",
      url: "https://gitlab.com/o/r.git"
    })
  })

  it("parses gitlab sources including subgroups and tree paths", () => {
    expect(parseSkillSource("gitlab:o/r")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://gitlab.com/o/r.git"
    })
    expect(parseSkillSource("https://gitlab.com/group/sub/repo")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://gitlab.com/group/sub/repo.git"
    })
    expect(parseSkillSource("https://gitlab.com/o/r/-/tree/main/skills/deploy")).toEqual({
      kind: "git",
      ref: "main",
      subpath: "skills/deploy",
      url: "https://gitlab.com/o/r.git"
    })
    expect(() => parseSkillSource("https://gitlab.com/only-owner")).toThrow("Not a repository URL")
    expect(parseSkillSource("https://gitlab.com/o/r/-/tree/main")).toEqual({
      kind: "git",
      ref: "main",
      url: "https://gitlab.com/o/r.git"
    })
    // An explicit #ref wins over the /-/tree/ segment.
    expect(parseSkillSource("https://gitlab.com/o/r/-/tree/main/path#pinned")).toEqual({
      kind: "git",
      ref: "pinned",
      subpath: "path",
      url: "https://gitlab.com/o/r.git"
    })
  })

  it("routes non-repository HTTPS URLs to well-known discovery", () => {
    expect(parseSkillSource("https://skills.example.com")).toEqual({
      kind: "wellKnown",
      url: "https://skills.example.com"
    })
    expect(parseSkillSource("https://example.com/docs/skills")).toEqual({
      kind: "wellKnown",
      url: "https://example.com/docs/skills"
    })
    // Explicit git remotes still clone.
    expect(parseSkillSource("https://myhost.dev/team/repo.git#dev")).toEqual({
      kind: "git",
      ref: "dev",
      url: "https://myhost.dev/team/repo.git"
    })
  })

  it("rejects empty and unrecognizable sources", () => {
    expect(() => parseSkillSource("  ")).toThrow(SkillsError)
    expect(() => parseSkillSource("just-a-name")).toThrow("Unrecognized skill source")
    expect(() => parseSkillSource("https://github.com/only-owner")).toThrow("Not a repository URL")
    // A trailing # is treated as no ref at all.
    expect(parseSkillSource("o/r#")).toEqual({
      kind: "git",
      ref: undefined,
      url: "https://github.com/o/r.git"
    })
  })
})

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

describe("importRemote", () => {
  const managerWithClone = (
    home: string,
    clone: (url: string, ref: string | undefined, destination: string) => Promise<void>
  ): SkillsManager =>
    makeSkillsManager({
      agents: makeAgentRuntime({}),
      env: {},
      homedir: home,
      overrides: { clone }
    })

  it("imports every skill found in a cloned repo", async () => {
    const home = makeHome()
    const calls: Array<[string, string | undefined]> = []
    const skills = managerWithClone(home, async (url, ref, destination) => {
      calls.push([url, ref])
      writeSkill(join(destination, "skills/deploy"), { name: "Deploy" })
      writeSkill(join(destination, "skills/review"), { name: "Review" })
      // Stray files, ignored locations, and too-deep nesting never import.
      writeFileSync(join(destination, "README.md"), "docs")
      mkdirSync(join(destination, "node_modules/ignored"), { recursive: true })
      writeFileSync(join(destination, "node_modules/ignored/SKILL.md"), "nope")
      writeSkill(join(destination, ".git/hooks"), { name: "Git Internals" })
      writeSkill(join(destination, "a/b/c/d/too-deep"), { name: "Too Deep" })
    })
    const scan = await skills.importRemote({ source: "vercel-labs/skills#main" })
    expect(calls).toEqual([["https://github.com/vercel-labs/skills.git", "main"]])
    expect(scan.global.map((skill) => skill.directoryName).sort()).toEqual(["deploy", "review"])
  })

  it("scopes discovery to the requested subpath", async () => {
    const home = makeHome()
    const skills = managerWithClone(home, async (_url, _ref, destination) => {
      writeSkill(join(destination, "skills/deploy"), { name: "Deploy" })
      writeSkill(join(destination, "skills/review"), { name: "Review" })
    })
    const scan = await skills.importRemote({ source: "o/r/skills/deploy" })
    expect(scan.global.map((skill) => skill.directoryName)).toEqual(["deploy"])
  })

  it("rejects subpath traversal, empty repos, and clone failures", async () => {
    const home = makeHome()
    await expect(
      managerWithClone(home, async () => {}).importRemote({ source: "o/r/../../etc" })
    ).rejects.toMatchObject({ code: "invalid" })
    await expect(
      managerWithClone(home, async () => {}).importRemote({ source: "o/empty" })
    ).rejects.toMatchObject({ code: "invalid" })
    await expect(
      managerWithClone(home, async () => {
        throw new Error("repository not found")
      }).importRemote({ source: "o/missing" })
    ).rejects.toMatchObject({ code: "invalid" })
    // A subpath that does not exist in the clone reads as no skills found.
    await expect(
      managerWithClone(home, async () => {}).importRemote({ source: "o/r/absent/dir" })
    ).rejects.toMatchObject({ code: "invalid" })
    // Non-Error clone failures with a pinned ref still produce a useful message.
    await expect(
      managerWithClone(home, async () => {
        throw "socket hangup"
      }).importRemote({ source: "o/missing#dev" })
    ).rejects.toThrow("(dev): socket hangup")
  })

  it("skips existing skills and fails only when nothing was imported", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    const clone = async (_url: string, _ref: string | undefined, destination: string) => {
      writeSkill(join(destination, "deploy"), { body: "different", name: "Deploy" })
      writeSkill(join(destination, "review"), { name: "Review" })
    }
    const scan = await managerWithClone(home, clone).importRemote({ source: "o/r" })
    expect(scan.global.map((skill) => skill.directoryName).sort()).toEqual(["deploy", "review"])
    // Second run: everything conflicts now.
    await expect(
      managerWithClone(home, clone).importRemote({ source: "o/r" })
    ).rejects.toMatchObject({ code: "conflict" })
  })

  it("surfaces default-clone failures as invalid sources", async () => {
    const home = makeHome()
    await expect(
      manager(home).importRemote({ source: join(home, "does-not-exist") })
    ).rejects.toMatchObject({ code: "invalid" })
  })

  it("clones for real from a local git repository", async () => {
    const home = makeHome()
    const upstream = join(home, "upstream")
    writeSkill(join(upstream, "my-skill"), { description: "From git", name: "My Skill" })
    execSync(
      `git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm skill`,
      { cwd: upstream }
    )
    // Pin the ref too, exercising the default clone's --branch path.
    const scan = await manager(home).importRemote({ source: `${upstream}#main` })
    expect(globalSkill(scan, "my-skill").description).toBe("From git")
  })
})

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

describe("well-known skill sources", () => {
  const startSkillSite = async (
    handler: (path: string) => { status: number; body: Buffer | string } | undefined
  ) => {
    const { createServer } = await import("node:http")
    const server = createServer((request, response) => {
      const result = handler(request.url ?? "/")
      if (result === undefined) {
        response.writeHead(404)
        response.end()
        return
      }
      response.writeHead(result.status)
      response.end(result.body)
    })
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
    const address = server.address()
    if (address === null || typeof address === "string") throw new Error("missing port")
    return {
      close: () => new Promise<void>((resolve) => server.close(() => resolve())),
      url: `http://127.0.0.1:${address.port}`
    }
  }

  it("imports legacy file-list skills from the well-known index", async () => {
    const home = makeHome()
    const site = await startSkillSite((path) => {
      if (path === "/.well-known/agent-skills/index.json") {
        return {
          status: 200,
          body: JSON.stringify({
            skills: [
              {
                name: "deploy",
                description: "Deploy checklist",
                files: ["SKILL.md", "refs/notes.md"]
              },
              { name: "broken", description: "missing files", files: ["SKILL.md"] }
            ]
          })
        }
      }
      if (path === "/.well-known/agent-skills/deploy/SKILL.md") {
        return {
          status: 200,
          body: "---\nname: Deploy\ndescription: Deploy checklist\n---\nSteps."
        }
      }
      if (path === "/.well-known/agent-skills/deploy/refs/notes.md") {
        return { status: 200, body: "notes" }
      }
      // The "broken" skill's file 404s — that entry must be skipped.
      return undefined
    })
    try {
      const scan = await manager(home).importRemote({ source: site.url })
      expect(globalSkill(scan, "deploy").description).toBe("Deploy checklist")
      expect(readFileSync(join(home, ".agents/skills/deploy/refs/notes.md"), "utf8")).toBe("notes")
      expect(scan.global.map((skill) => skill.directoryName)).toEqual(["deploy"])
      // Auto-install applied to well-known imports too.
      expect(installState(scan, "deploy", "claude-code")).toBe("linked")
    } finally {
      await site.close()
    }
  })

  it("imports v0.2.0 skill-md and tar.gz archive artifacts with digest checks", async () => {
    const home = makeHome()
    const { execSync } = await import("node:child_process")
    const { createHash } = await import("node:crypto")
    // Build a tgz artifact containing an archived skill.
    const artifactSource = join(home, "artifact-src")
    writeSkill(join(artifactSource, "archived"), { description: "From archive", name: "Archived" })
    execSync(`tar -czf ${join(home, "archived.tgz")} -C ${artifactSource} archived`)
    const archiveBytes = readFileSync(join(home, "archived.tgz"))
    const archiveDigest = `sha256:${createHash("sha256").update(archiveBytes).digest("hex")}`
    const singleBody = "---\nname: Single\ndescription: Just one file\n---\nBody."
    const singleDigest = `sha256:${createHash("sha256").update(Buffer.from(singleBody)).digest("hex")}`

    const site = await startSkillSite((path) => {
      if (path === "/.well-known/agent-skills/index.json") {
        return {
          status: 200,
          body: JSON.stringify({
            $schema: "v2",
            skills: [
              {
                name: "single",
                type: "skill-md",
                description: "one",
                url: "single.md",
                digest: singleDigest
              },
              {
                name: "archived",
                type: "archive",
                description: "arch",
                url: "archived.tgz",
                digest: archiveDigest
              },
              {
                name: "tampered",
                type: "archive",
                description: "bad",
                url: "archived.tgz",
                digest: "sha256:deadbeef"
              },
              {
                name: "",
                type: "skill-md",
                description: "nameless",
                url: "single.md",
                digest: singleDigest
              },
              { description: "no url either" }
            ]
          })
        }
      }
      if (path === "/.well-known/agent-skills/single.md") return { status: 200, body: singleBody }
      if (path === "/.well-known/agent-skills/archived.tgz")
        return { status: 200, body: archiveBytes }
      return undefined
    })
    try {
      const scan = await manager(home).importRemote({ source: site.url })
      expect(scan.global.map((skill) => skill.directoryName).sort()).toEqual(["archived", "single"])
      expect(globalSkill(scan, "archived").description).toBe("From archive")
    } finally {
      await site.close()
    }
  })

  it("falls back to the origin and legacy well-known paths", async () => {
    const home = makeHome()
    const site = await startSkillSite((path) => {
      if (path === "/.well-known/skills/index.json") {
        return {
          status: 200,
          body: JSON.stringify({
            skills: [{ name: "deploy", description: "d", files: ["SKILL.md"] }]
          })
        }
      }
      if (path === "/.well-known/skills/deploy/SKILL.md") {
        return { status: 200, body: "---\nname: Deploy\ndescription: d\n---\nx" }
      }
      return undefined
    })
    try {
      // A deep page URL still resolves through the origin's legacy path.
      const scan = await manager(home).importRemote({ source: `${site.url}/docs/page/` })
      expect(globalSkill(scan, "deploy")).toBeDefined()
    } finally {
      await site.close()
    }
  })

  it("tolerates malformed indexes, bad entries, and broken archives", async () => {
    const home = makeHome()
    const { execSync } = await import("node:child_process")
    const { createHash } = await import("node:crypto")
    // A zip artifact, and a corrupt "gzip" artifact (valid magic, garbage body).
    const zipSource = join(home, "zip-src")
    writeSkill(join(zipSource, "zipped"), { description: "From zip", name: "Zipped" })
    execSync(`cd ${zipSource} && zip -qr ${join(home, "zipped.zip")} zipped`)
    const zipBytes = readFileSync(join(home, "zipped.zip"))
    const zipDigest = `sha256:${createHash("sha256").update(zipBytes).digest("hex")}`
    const corruptGzip = Buffer.concat([Buffer.from([0x1f, 0x8b]), Buffer.from("garbage")])
    const corruptDigest = `sha256:${createHash("sha256").update(corruptGzip).digest("hex")}`
    const plainBytes = Buffer.from("not an archive")
    const plainDigest = `sha256:${createHash("sha256").update(plainBytes).digest("hex")}`

    const site = await startSkillSite((path) => {
      // The path-relative candidate serves invalid JSON; the origin's
      // agent-skills index serves a non-array shape; the legacy origin
      // index finally works — exercising the whole candidate chain.
      if (path === "/docs/.well-known/agent-skills/index.json") {
        return { status: 200, body: "{ not json" }
      }
      if (path === "/.well-known/agent-skills/index.json") {
        return { status: 200, body: JSON.stringify({ skills: "nope" }) }
      }
      if (path === "/.well-known/skills/index.json") {
        return {
          status: 200,
          body: JSON.stringify({
            skills: [
              {
                name: "zipped",
                type: "archive",
                description: "z",
                url: "zipped.zip",
                digest: zipDigest
              },
              {
                name: "corrupt",
                type: "archive",
                description: "c",
                url: "corrupt.tgz",
                digest: corruptDigest
              },
              {
                name: "notarchive",
                type: "archive",
                description: "p",
                url: "plain.bin",
                digest: plainDigest
              },
              {
                name: "gone",
                type: "archive",
                description: "g",
                url: "missing.tgz",
                digest: "sha256:x"
              },
              { name: "nourl", description: "entry without url or files" },
              { name: "oddfiles", description: "odd", files: ["SKILL.md", 42, "../evil.md"] },
              { name: "nodigest", type: "skill-md", description: "nd", url: "nodigest.md" },
              "not-an-object"
            ]
          })
        }
      }
      if (path === "/.well-known/skills/zipped.zip") return { status: 200, body: zipBytes }
      if (path === "/.well-known/skills/corrupt.tgz") return { status: 200, body: corruptGzip }
      if (path === "/.well-known/skills/plain.bin") return { status: 200, body: plainBytes }
      if (path === "/.well-known/skills/nodigest.md") {
        return { status: 200, body: "---\nname: No Digest\ndescription: nd\n---\nx" }
      }
      if (path === "/.well-known/skills/oddfiles/SKILL.md") {
        return { status: 200, body: "---\nname: Odd Files\ndescription: odd\n---\nx" }
      }
      return undefined
    })
    try {
      const scan = await manager(home).importRemote({ source: `${site.url}/docs` })
      expect(scan.global.map((skill) => skill.directoryName).sort()).toEqual([
        "no-digest",
        "odd-files",
        "zipped"
      ])
      expect(globalSkill(scan, "zipped").description).toBe("From zip")
    } finally {
      await site.close()
    }
  })

  it("fails cleanly when a site publishes nothing", async () => {
    const home = makeHome()
    const site = await startSkillSite(() => undefined)
    try {
      await expect(manager(home).importRemote({ source: site.url })).rejects.toMatchObject({
        code: "invalid"
      })
    } finally {
      await site.close()
    }
  })
})

describe("remote discovery and selective import", () => {
  const cloneWithTwoSkills = async (
    _url: string,
    _ref: string | undefined,
    destination: string
  ) => {
    writeSkill(join(destination, "skills/deploy"), { description: "Deploys", name: "Deploy" })
    writeSkill(join(destination, "skills/review"), { description: "Reviews", name: "Review" })
    // Broken frontmatter: named by its directory, no description.
    mkdirSync(join(destination, "skills/plain"), { recursive: true })
    writeFileSync(join(destination, "skills/plain/SKILL.md"), "---\n- broken\n---\n")
  }

  it("lists a source's skills with existence flags without importing", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    const skills = makeSkillsManager({
      agents: makeAgentRuntime({}),
      env: {},
      homedir: home,
      overrides: { clone: cloneWithTwoSkills }
    })
    const discovered = await skills.discoverRemote({ source: "o/r" })
    expect(discovered.skills).toEqual([
      { alreadyExists: true, description: "Deploys", directoryName: "deploy", name: "Deploy" },
      { alreadyExists: false, directoryName: "plain", name: "plain" },
      { alreadyExists: false, description: "Reviews", directoryName: "review", name: "Review" }
    ])
    // Nothing was imported.
    expect(existsSync(join(home, ".agents/skills/review"))).toBe(false)
  })

  it("imports only the selected skills", async () => {
    const home = makeHome()
    const skills = makeSkillsManager({
      agents: makeAgentRuntime({}),
      env: {},
      homedir: home,
      overrides: { clone: cloneWithTwoSkills }
    })
    const scan = await skills.importRemote({ skillNames: ["Review", "plain"], source: "o/r" })
    expect(scan.global.map((skill) => skill.directoryName)).toEqual(["plain", "review"])
    await expect(
      skills.importRemote({ skillNames: ["ghost"], source: "o/r" })
    ).rejects.toMatchObject({ code: "notFound" })
  })
})
