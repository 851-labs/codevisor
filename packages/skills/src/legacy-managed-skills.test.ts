import { existsSync, lstatSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { makeAgentRuntime } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it } from "vitest"

import {
  importLegacyUserSkills,
  LEGACY_IMPORT_MARKER,
  migrateLegacySkills,
  removeLegacyManagedSkills
} from "./legacy-managed-skills.js"
import { MANAGED_SKILL_MARKER, MANAGED_SKILL_MARKER_CONTENT } from "./skills-store.js"
import { cleanupSkillsTests, makeHome, storeDir, writeSkill } from "./skills-test-support.js"

afterEach(cleanupSkillsTests)

const environment = (home: string, env: Record<string, string | undefined> = {}) => ({
  agents: makeAgentRuntime({}),
  env,
  homedir: home
})

const present = (path: string): boolean => {
  try {
    lstatSync(path)
    return true
  } catch {
    return false
  }
}

const managedSkill = (dir: string, marker = MANAGED_SKILL_MARKER_CONTENT): void => {
  writeSkill(dir, { name: "Managed" })
  writeFileSync(join(dir, MANAGED_SKILL_MARKER), marker)
}

describe("removeLegacyManagedSkills", () => {
  it("removes Codevisor's skills and their links, and nothing of the user's", async () => {
    const home = makeHome()
    const agents = join(home, ".agents/skills")
    managedSkill(join(agents, "browser-use"))
    managedSkill(join(agents, "codevisor"))
    managedSkill(join(agents, "lookalike"), "someone else's marker\n")
    writeSkill(join(agents, "my-skill"), { name: "Mine" })
    writeSkill(join(home, "elsewhere/browser-use"), { name: "Mine too" })
    mkdirSync(join(home, ".claude/skills"), { recursive: true })
    mkdirSync(join(home, ".codex/skills"), { recursive: true })
    // Relative and absolute links to managed skills.
    symlinkSync("../../.agents/skills/browser-use", join(home, ".claude/skills/browser-use"))
    symlinkSync(join(agents, "codevisor"), join(home, ".codex/skills/codevisor"))
    // The user's own links and folders, including same-named ones.
    symlinkSync(join(agents, "my-skill"), join(home, ".claude/skills/my-skill"))
    symlinkSync(join(home, "elsewhere/browser-use"), join(home, ".codex/skills/browser-use"))
    writeSkill(join(home, ".claude/skills/codevisor"), { name: "Unmarked" })
    writeFileSync(join(home, ".claude/skills/notes.txt"), "not a skill")
    // A copy made where linking failed carries the marker.
    managedSkill(join(home, ".gemini/skills/computer-use"))
    // A harness folder that is the shared folder under another name.
    mkdirSync(join(home, ".config"), { recursive: true })
    symlinkSync(agents, join(home, ".config/agents"))

    const removed = await removeLegacyManagedSkills(environment(home))

    expect(removed.toSorted()).toEqual(
      [
        join(agents, "browser-use"),
        join(agents, "codevisor"),
        join(home, ".claude/skills/browser-use"),
        join(home, ".codex/skills/codevisor"),
        join(home, ".gemini/skills/computer-use")
      ].toSorted()
    )
    for (const kept of [
      join(agents, "my-skill"),
      join(agents, "lookalike"),
      join(home, ".claude/skills/my-skill"),
      join(home, ".codex/skills/browser-use"),
      join(home, ".claude/skills/codevisor")
    ]) {
      expect(present(kept)).toBe(true)
    }
    expect(await removeLegacyManagedSkills(environment(home))).toEqual([])
  })

  it("clears links left dangling by an interrupted earlier cleanup", async () => {
    const home = makeHome()
    mkdirSync(join(home, ".agents/skills"), { recursive: true })
    mkdirSync(join(home, ".claude/skills"), { recursive: true })
    symlinkSync(join(home, ".agents/skills/codevisor"), join(home, ".claude/skills/codevisor"))
    symlinkSync(join(home, ".agents/skills/gone"), join(home, ".claude/skills/gone"))
    // The user's own folder under a former managed name keeps its links.
    writeSkill(join(home, ".agents/skills/browser-use"), { name: "Mine" })
    symlinkSync(join(home, ".agents/skills/browser-use"), join(home, ".claude/skills/browser-use"))
    expect(await removeLegacyManagedSkills(environment(home))).toEqual([
      join(home, ".claude/skills/codevisor")
    ])
    expect(present(join(home, ".claude/skills/gone"))).toBe(true)
    expect(present(join(home, ".claude/skills/browser-use"))).toBe(true)
  })

  it("honors CODEX_HOME and tolerates a missing shared folder", async () => {
    const home = makeHome()
    const codexHome = join(home, "custom-codex")
    managedSkill(join(codexHome, "skills/browser-use"))
    expect(await removeLegacyManagedSkills(environment(home, { CODEX_HOME: codexHome }))).toEqual([
      join(codexHome, "skills/browser-use")
    ])
  })
})

describe("importLegacyUserSkills", () => {
  it("copies the user's skills into the store once and leaves the originals", async () => {
    const home = makeHome()
    const agents = join(home, ".agents/skills")
    writeSkill(join(agents, "deploy"), { name: "Deploy" })
    mkdirSync(join(agents, "deploy/scripts"))
    writeFileSync(join(agents, "deploy/scripts/run.sh"), "echo hi")
    writeSkill(join(home, "linked-source"), { name: "Linked" })
    symlinkSync(join(home, "linked-source"), join(agents, "linked"))
    managedSkill(join(agents, "browser-use"))
    writeSkill(join(agents, "attaching-files"), { name: "attaching-files" })
    writeSkill(join(agents, ".hidden"), { name: "Hidden" })
    mkdirSync(join(agents, "empty"))
    writeFileSync(join(agents, "notes.txt"), "x")
    symlinkSync(join(home, "missing"), join(agents, "dangling"))
    writeSkill(join(storeDir(home), "taken"), { name: "Taken" })
    writeSkill(join(agents, "taken"), { body: "different", name: "Taken" })

    const imported = await importLegacyUserSkills({
      ...environment(home),
      storeDir: storeDir(home)
    })

    expect(imported.toSorted()).toEqual(["deploy", "linked"])
    expect(readFileSync(join(storeDir(home), "deploy/scripts/run.sh"), "utf8")).toBe("echo hi")
    expect(existsSync(join(agents, "deploy/SKILL.md"))).toBe(true)
    expect(readFileSync(join(storeDir(home), "taken/SKILL.md"), "utf8")).not.toContain("different")
    expect(JSON.parse(readFileSync(join(storeDir(home), LEGACY_IMPORT_MARKER), "utf8"))).toEqual({
      imported
    })

    writeSkill(join(agents, "later"), { name: "Later" })
    expect(
      await importLegacyUserSkills({ ...environment(home), storeDir: storeDir(home) })
    ).toEqual([])
    expect(existsSync(join(storeDir(home), "later"))).toBe(false)
  })

  it("records completion when there is no shared folder", async () => {
    const home = makeHome()
    expect(
      await importLegacyUserSkills({ ...environment(home), storeDir: storeDir(home) })
    ).toEqual([])
    expect(existsSync(join(storeDir(home), LEGACY_IMPORT_MARKER))).toBe(true)
  })
})

describe("migrateLegacySkills", () => {
  it("removes Codevisor's skills before importing the user's", async () => {
    const home = makeHome()
    managedSkill(join(home, ".agents/skills/codevisor"))
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    expect(await migrateLegacySkills({ ...environment(home), storeDir: storeDir(home) })).toEqual([
      "deploy"
    ])
    expect(present(join(home, ".agents/skills/codevisor"))).toBe(false)
    expect(present(join(storeDir(home), "codevisor"))).toBe(false)
  })
})
