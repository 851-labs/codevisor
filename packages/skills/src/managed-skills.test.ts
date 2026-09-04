import { lstatSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { managedAttachmentSkill } from "./managed-skills.js"
import { cleanupSkillsTests, makeHome, manager } from "./skills-test-support.js"

afterEach(cleanupSkillsTests)

describe("attachment skill", () => {
  it("finds the repository fallback and reports missing packaged resources", () => {
    const root = join(managedAttachmentSkill().sourcePath, "../../../..")
    expect(managedAttachmentSkill("/missing/runtime", root).sourcePath).toBe(
      managedAttachmentSkill().sourcePath
    )
    expect(() => managedAttachmentSkill("/missing/runtime", "/missing/worktree")).toThrow(
      "Missing packaged attaching-files skill"
    )
  })

  it("installs independently in every harness", async () => {
    const home = makeHome()
    const skills = manager(home)
    await skills.syncManaged([managedAttachmentSkill()])
    const scan = await skills.list()
    expect(scan.global.some((skill) => skill.directoryName === "attaching-files")).toBe(false)
    expect(lstatSync(join(home, ".codex/skills/attaching-files")).isSymbolicLink()).toBe(true)
    expect(lstatSync(join(home, ".claude/skills/attaching-files")).isSymbolicLink()).toBe(true)
    expect(readFileSync(join(home, ".agents/skills/attaching-files/SKILL.md"), "utf8")).toContain(
      "[View recording]"
    )
  })
})
