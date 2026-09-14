import { existsSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { MANAGED_SKILL_MARKER, MANAGED_SKILL_MARKER_CONTENT } from "./skills-store.js"
import {
  cleanupSkillsTests,
  globalSkill,
  makeHome,
  manager,
  writeSkill
} from "./skills-test-support.js"

afterEach(cleanupSkillsTests)

const updatedContent =
  "---\nname: Release Checklist\ndescription: Prepare a release\nallowed-tools: Bash\n---\n\nReview, then ship.\n"

describe("skill editing", () => {
  it("reads the full document and saves edits without renaming or losing supporting files", async () => {
    const home = makeHome()
    const skills = manager(home)
    await skills.create({ name: "deploy", description: "Deploy checklist" })
    const path = join(home, ".agents/skills/deploy")
    mkdirSync(join(path, "references"))
    writeFileSync(join(path, "references/checklist.md"), "Supporting instructions")
    const original = readFileSync(join(path, "SKILL.md"), "utf8")
    expect(await skills.read("deploy")).toEqual({ content: original })

    const scan = await skills.update("deploy", { content: updatedContent })
    expect(globalSkill(scan, "deploy")).toMatchObject({
      name: "Release Checklist",
      description: "Prepare a release",
      path
    })
    expect(existsSync(join(home, ".agents/skills/release-checklist"))).toBe(false)
    expect(await skills.read("deploy")).toEqual({ content: updatedContent })
    expect(readFileSync(join(path, "references/checklist.md"), "utf8")).toBe(
      "Supporting instructions"
    )
    expect(readFileSync(join(home, ".claude/skills/deploy/SKILL.md"), "utf8")).toBe(updatedContent)
  })

  it("lets the editor read and repair a malformed document", async () => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { body: "---\n- broken\n---\n" })
    const skills = manager(home)
    expect((await skills.read("deploy")).content).toContain("- broken")
    const scan = await skills.update("deploy", { content: updatedContent })
    expect(globalSkill(scan, "deploy").invalid).not.toBe(true)
  })

  it.each([
    "---\n- broken\n---\n",
    "---\nname: [invalid\n---\n",
    "No frontmatter",
    "---\nname: 123\ndescription: Description\n---\n",
    "---\nname: ' '\ndescription: Description\n---\n",
    "---\nname: Deploy\n---\n",
    "---\nname: Deploy\ndescription: 123\n---\n",
    "---\nname: Deploy\ndescription: ' '\n---\n"
  ])("rejects invalid metadata without changing the file: %s", async (content) => {
    const home = makeHome()
    writeSkill(join(home, ".agents/skills/deploy"), { name: "Deploy" })
    const skills = manager(home)
    const original = await skills.read("deploy")
    await expect(skills.update("deploy", { content })).rejects.toMatchObject({ code: "invalid" })
    expect(await skills.read("deploy")).toEqual(original)
  })

  it.each(["../outside", "missing"])("rejects reads and writes to %s", async (name) => {
    const skills = manager(makeHome())
    const code = name === "missing" ? "notFound" : "invalid"
    await expect(skills.read(name)).rejects.toMatchObject({ code })
    await expect(skills.update(name, { content: updatedContent })).rejects.toMatchObject({ code })
  })

  it("rejects skill folders and documents linked outside the canonical store", async () => {
    const home = makeHome()
    const outside = join(home, "outside")
    writeSkill(outside, { name: "Outside" })
    const original = readFileSync(join(outside, "SKILL.md"), "utf8")
    const canonical = join(home, ".agents/skills")
    mkdirSync(join(canonical, "linked-file"), { recursive: true })
    symlinkSync(outside, join(canonical, "linked-folder"))
    symlinkSync(join(outside, "SKILL.md"), join(canonical, "linked-file/SKILL.md"))
    const skills = manager(home)
    await Promise.all(
      ["linked-folder", "linked-file"].map(async (name) => {
        await expect(skills.read(name)).rejects.toMatchObject({ code: "invalid" })
        await expect(skills.update(name, { content: updatedContent })).rejects.toMatchObject({
          code: "invalid"
        })
      })
    )
    expect(readFileSync(join(outside, "SKILL.md"), "utf8")).toBe(original)
  })

  it("protects app-managed skills from editing", async () => {
    const home = makeHome()
    const path = join(home, ".agents/skills/managed")
    writeSkill(path, { name: "Managed" })
    writeFileSync(join(path, MANAGED_SKILL_MARKER), MANAGED_SKILL_MARKER_CONTENT)
    const skills = manager(home)
    await expect(skills.read("managed")).rejects.toMatchObject({ code: "invalid" })
    await expect(skills.update("managed", { content: updatedContent })).rejects.toMatchObject({
      code: "invalid"
    })
  })

  it("supports a canonical store whose parent is symlinked", async () => {
    const home = makeHome()
    const actual = join(home, "actual-agents")
    writeSkill(join(actual, "skills/deploy"), { name: "Deploy" })
    symlinkSync(actual, join(home, ".agents"))
    const skills = manager(home)
    await skills.update("deploy", { content: updatedContent })
    expect(await skills.read("deploy")).toEqual({ content: updatedContent })
  })
})
