import { existsSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { attachingFilesSkill } from "./managed-skills.js"
import {
  cleanupSkillsTests,
  makeHome,
  manager,
  storeDir,
  storedSkill,
  writeSkill
} from "./skills-test-support.js"

afterEach(cleanupSkillsTests)

const counting = (store: ReturnType<typeof manager>) => {
  let changes = 0
  const unsubscribe = store.subscribe(() => {
    changes += 1
  })
  return { changes: () => changes, unsubscribe }
}

describe("skill store contents", () => {
  it("lists only skill folders, sorted, and treats a missing store as empty", async () => {
    const home = makeHome()
    expect(await manager(home).list()).toEqual({ dir: storeDir(home), skills: [] })
    writeSkill(join(storeDir(home), "zeta"), { description: "Last", name: "Zeta" })
    writeSkill(join(storeDir(home), "alpha"), { name: "Alpha" })
    writeSkill(join(storeDir(home), ".hidden"), { name: "Hidden" })
    mkdirSync(join(storeDir(home), "no-skill-file"))
    writeFileSync(join(storeDir(home), "loose.md"), "not a skill")
    mkdirSync(join(storeDir(home), "broken"))
    writeFileSync(join(storeDir(home), "broken/SKILL.md"), "---\n- not a mapping\n---\n")
    mkdirSync(join(storeDir(home), "nameless"))
    writeFileSync(join(storeDir(home), "nameless/SKILL.md"), '---\nname: ""\n---\nBody\n')
    const list = await manager(home).list()
    expect(list.skills.map((skill) => skill.directoryName)).toEqual([
      "alpha",
      "broken",
      "nameless",
      "zeta"
    ])
    // An empty frontmatter name falls back to the folder name.
    expect(storedSkill(list, "nameless").name).toBe("nameless")
    expect(storedSkill(list, "zeta")).toMatchObject({ description: "Last", name: "Zeta" })
    expect(storedSkill(list, "broken")).toEqual({
      directoryName: "broken",
      invalid: true,
      name: "broken",
      path: join(storeDir(home), "broken")
    })
  })

  it("creates skills from the form, a pasted body, or pasted frontmatter", async () => {
    const home = makeHome()
    const store = manager(home)
    const events = counting(store)
    await store.create({ description: "", name: "Ship It" })
    expect(readFileSync(join(storeDir(home), "ship-it/SKILL.md"), "utf8")).toContain(
      'description: "Ship It"'
    )
    await store.create({ content: "Run the tests.", description: "Runs tests", name: "Test" })
    expect(readFileSync(join(storeDir(home), "test/SKILL.md"), "utf8")).toContain("Run the tests.")
    const list = await store.create({
      content: "---\nname: Own Name\ndescription: Pasted\n---\nBody",
      description: "",
      name: "Ignored"
    })
    expect(storedSkill(list, "own-name").description).toBe("Pasted")
    await store.create({
      content: "---\ndescription: No name\n---\nBody",
      description: "",
      name: "Fallback"
    })
    expect(existsSync(join(storeDir(home), "fallback/SKILL.md"))).toBe(true)
    expect(events.changes()).toBe(4)
  })

  it("rejects blank, invalid, duplicate, and built-in names", async () => {
    const store = manager(makeHome())
    await expect(store.create({ description: "", name: "  " })).rejects.toMatchObject({
      code: "invalid"
    })
    await expect(
      store.create({ content: "---\n- broken\n---\n", description: "", name: "x" })
    ).rejects.toMatchObject({ code: "invalid" })
    await expect(store.create({ description: "", name: "browser-use" })).rejects.toMatchObject({
      code: "conflict"
    })
    await store.create({ description: "", name: "Deploy" })
    await expect(store.create({ description: "", name: "Deploy" })).rejects.toMatchObject({
      code: "conflict"
    })
  })

  it("reads and updates a skill's SKILL.md with valid frontmatter only", async () => {
    const home = makeHome()
    const store = manager(home)
    await store.create({ description: "Deploys", name: "Deploy" })
    expect((await store.read("deploy")).content).toContain("Deploys")
    const events = counting(store)
    const updated = "---\nname: Deploy\ndescription: Ships to prod\n---\nNew body\n"
    expect(
      storedSkill(await store.update("deploy", { content: updated }), "deploy").description
    ).toBe("Ships to prod")
    expect(events.changes()).toBe(1)
    await expect(store.update("deploy", { content: "---\n- x\n---\n" })).rejects.toMatchObject({
      code: "invalid"
    })
    await expect(
      store.update("deploy", { content: "---\nname: Deploy\n---\nNo description" })
    ).rejects.toMatchObject({ code: "invalid" })
    await expect(store.read("missing")).rejects.toMatchObject({ code: "notFound" })
    await expect(store.read("../escape")).rejects.toMatchObject({ code: "invalid" })
  })

  it("refuses a SKILL.md that links outside the store", async () => {
    const home = makeHome()
    writeSkill(join(home, "elsewhere"), { name: "Elsewhere" })
    mkdirSync(join(storeDir(home), "linked"), { recursive: true })
    symlinkSync(join(home, "elsewhere/SKILL.md"), join(storeDir(home), "linked/SKILL.md"))
    await expect(manager(home).read("linked")).rejects.toMatchObject({ code: "notFound" })
  })

  it("removes skills and stops notifying after unsubscribe", async () => {
    const home = makeHome()
    const store = manager(home)
    await store.create({ description: "", name: "Deploy" })
    const events = counting(store)
    expect((await store.remove("deploy")).skills).toEqual([])
    await expect(store.remove("deploy")).rejects.toMatchObject({ code: "notFound" })
    events.unsubscribe()
    await store.create({ description: "", name: "Again" })
    expect(events.changes()).toBe(1)
  })
})

describe("sync and tool seams", () => {
  it("replaces and renames skills in place", async () => {
    const home = makeHome()
    const store = manager(home)
    await store.create({ description: "Old", name: "Deploy" })
    writeSkill(join(home, "incoming"), { description: "Replicated", name: "Deploy" })
    const events = counting(store)
    await store.replace("deploy", join(home, "incoming"))
    await store.rename("deploy", "deploy-2")
    expect(storedSkill(await store.list(), "deploy-2").description).toBe("Replicated")
    expect(events.changes()).toBe(2)
  })

  it("documents a skill with its supporting files", async () => {
    const home = makeHome()
    const root = join(storeDir(home), "deploy")
    writeSkill(root, { name: "Deploy" })
    mkdirSync(join(root, "scripts"))
    writeFileSync(join(root, "scripts/run.sh"), "echo hi")
    writeFileSync(join(root, "reference.md"), "ref")
    mkdirSync(join(root, ".git"))
    writeFileSync(join(root, ".git/HEAD"), "ref")
    mkdirSync(join(root, "node_modules"))
    writeFileSync(join(root, "node_modules/x.js"), "x")
    const document = await manager(home).document("deploy")
    expect(document).toEqual({
      content: readFileSync(join(root, "SKILL.md"), "utf8"),
      files: ["reference.md", "scripts/run.sh"],
      path: root
    })
    expect(await manager(home).document("missing")).toBeUndefined()
  })

  it("caps the listed supporting files", async () => {
    const home = makeHome()
    const root = join(storeDir(home), "big")
    writeSkill(root, { name: "Big" })
    for (let index = 0; index < 60; index += 1) {
      writeFileSync(join(root, `file-${String(index).padStart(2, "0")}.md`), "x")
    }
    mkdirSync(join(root, "zz"))
    writeFileSync(join(root, "zz/late.md"), "x")
    expect((await manager(home).document("big"))?.files).toHaveLength(50)
  })
})

describe("packaged skills", () => {
  it("locates the attaching-files skill and fails loudly when it is missing", () => {
    expect(readFileSync(attachingFilesSkill().path, "utf8")).toContain("attaching-files")
    expect(() => attachingFilesSkill("/nowhere", "/nowhere")).toThrow(
      "Missing packaged attaching-files skill"
    )
  })
})
