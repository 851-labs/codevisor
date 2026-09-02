import { makeAgentRuntime } from "@codevisor/agent-runtime"
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readlinkSync,
  symlinkSync,
  writeFileSync
} from "node:fs"
import { join } from "node:path"
import { makeSkillsManager } from "./skills-manager.js"
import type { SkillsManager } from "./skills-manager.js"
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
