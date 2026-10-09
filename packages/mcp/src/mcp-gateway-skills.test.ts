import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { codevisorSandboxSignatures } from "@codevisor/automation"
import { afterEach, describe, expect, it, vi } from "vitest"

import { automationSkills } from "./mcp-automation-builtins.js"
import {
  composerSkills,
  executeSkill,
  packagedSkill,
  skillEntries,
  skillsToolDescription,
  skillsToolResult,
  type SkillSource
} from "./mcp-gateway-skills.js"
import { reportBackgroundFailure } from "./mcp-support.js"

const directories: Array<string> = []
afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true })
})

const allEnabled = {
  enabledIds: new Set(["browser", "computer", "codevisor"]),
  pluginTools: []
}

const source = (
  skills: ReadonlyArray<{ directoryName: string; name: string; description?: string }>,
  documents: Record<string, { content: string; path: string; files: ReadonlyArray<string> }> = {}
): SkillSource => ({
  document: async (directoryName) => documents[directoryName],
  list: async () => ({ skills }),
  subscribe: () => () => undefined
})

describe("skill catalog", () => {
  it("shows built-ins only while their server is enabled, then the user's skills", async () => {
    const entries = await skillEntries(
      [executeSkill, ...automationSkills()],
      { enabledIds: new Set(["browser"]), pluginTools: [] },
      source([
        { description: "Ships it", directoryName: "deploy", name: "Deploy" },
        { directoryName: "browser-use", name: "Shadow" },
        { directoryName: "plain", name: "Plain" }
      ])
    )
    expect(entries.map((entry) => [entry.name, entry.builtin])).toEqual([
      ["execute", true],
      ["browser-use", true],
      ["deploy", false],
      ["plain", false]
    ])
    expect(entries.find((entry) => entry.name === "plain")?.summary).toBe("Plain")
    expect(await skillEntries([], allEnabled, undefined)).toEqual([])
  })

  it("offers the composer only the guides users invoke, then the user's skills", async () => {
    const attaching = packagedSkill({
      composer: "Send you files",
      name: "attaching-files",
      path: () => "/missing/SKILL.md",
      summary: "send files to the user"
    })
    const entries = await skillEntries(
      [executeSkill, ...automationSkills(), attaching],
      { enabledIds: new Set(["browser", "codevisor"]), pluginTools: [] },
      source([
        { description: "Ships it", directoryName: "deploy", name: "Deploy" },
        { directoryName: "plain", name: "Plain" }
      ])
    )
    expect(composerSkills(entries)).toEqual([
      {
        builtin: true,
        description: "Browse the web with Codevisor's browser",
        name: "browser-use"
      },
      {
        builtin: true,
        description: "Start and coordinate other agents in Codevisor",
        name: "codevisor-agents"
      },
      { builtin: true, description: "Send you files", name: "attaching-files" },
      { builtin: false, description: "Ships it", name: "deploy" },
      { builtin: false, name: "plain" }
    ])
  })

  it("reads built-in skills without frontmatter, tolerating malformed files", async () => {
    const browser = (await skillEntries(automationSkills(), allEnabled, undefined))[0]
    const text = await browser?.read()
    expect(text?.startsWith("---")).toBe(false)
    expect(text).toContain("browser")

    const directory = mkdtempSync(join(tmpdir(), "codevisor-packaged-skill-"))
    directories.push(directory)
    writeFileSync(join(directory, "SKILL.md"), "---\n- not a mapping\n---\nBody\n")
    const broken = packagedSkill({
      name: "broken",
      path: () => join(directory, "SKILL.md"),
      summary: "Broken"
    })
    expect(await broken.load(allEnabled)).toBe("---\n- not a mapping\n---\nBody")
  })

  it("reads user skills with their folder and supporting files", async () => {
    const entries = await skillEntries(
      [],
      allEnabled,
      source(
        [
          { directoryName: "deploy", name: "Deploy" },
          { directoryName: "bare", name: "Bare" }
        ],
        {
          bare: { content: "Just a body\n", files: [], path: "/store/bare" },
          deploy: {
            content: "---\nname: Deploy\ndescription: x\n---\nSteps\n",
            files: ["scripts/run.sh"],
            path: "/store/deploy"
          }
        }
      )
    )
    expect(await entries[0]?.read()).toBe(
      "Steps\n\nSkill folder: /store/deploy\n\nSupporting files (relative to the skill folder; open them with your file tools): scripts/run.sh"
    )
    expect(await entries[1]?.read()).toBe("Just a body")
  })

  it("generates the execute guide for the session's capabilities", async () => {
    const full = await executeSkill.load({
      enabledIds: new Set(["browser", "computer", "codevisor"]),
      pluginTools: [
        { description: "Append a note", inputSchema: { type: "object" }, name: "o.n.add" }
      ]
    })
    expect(full).toContain("`description` is the label the user sees")
    expect(full).toContain("read `browser-use`")
    expect(full).toContain("## Other agents")
    expect(full).toContain("- plugin.o.n.add — Append a note")
    expect(full).toContain(codevisorSandboxSignatures)

    const minimal = await executeSkill.load({ enabledIds: new Set(), pluginTools: [] })
    expect(minimal).not.toContain("browser-use")
    expect(minimal).not.toContain("## Other agents")
    expect(minimal).not.toContain("plugin tools")
    expect(minimal).toContain("attaching-files")
  })
})

describe("skills tool", () => {
  it("describes built-ins and as many user skills as fit the length budget", async () => {
    const builtins = await skillEntries(
      [executeSkill, ...automationSkills()],
      allEnabled,
      undefined
    )
    const plain = skillsToolDescription(builtins)
    expect(plain).not.toContain("The user's skills")
    expect(plain).toContain("- browser-use — drive a real web browser")

    const many = Array.from({ length: 40 }, (_, index) => ({
      description: `${"Long description ".repeat(10)}${index}`,
      directoryName: `skill-${String(index).padStart(2, "0")}`,
      name: `Skill ${index}`
    }))
    const description = skillsToolDescription(
      await skillEntries([executeSkill], allEnabled, source(many))
    )
    expect(description.length).toBeLessThanOrEqual(1_900)
    expect(description).toContain("- skill-00 — ")
    expect(description).toContain("…\n")
    expect(description).toMatch(/- …and \d+ more \(call with no name\)$/)

    const fits = skillsToolDescription(await skillEntries([], allEnabled, source(many.slice(0, 2))))
    expect(fits).toContain("- skill-01 — ")
    expect(fits).not.toContain("more (call with no name)")
  })

  it("lists, reads, and reports unknown or vanished skills", async () => {
    const entries = await skillEntries(
      [executeSkill],
      allEnabled,
      source([{ directoryName: "gone", name: "Gone" }])
    )
    expect((await skillsToolResult(entries, undefined)).text).toContain("- execute — ")
    expect((await skillsToolResult(entries, " ")).isError).toBe(false)
    expect((await skillsToolResult(entries, "execute")).text).toContain("# execute")
    expect(await skillsToolResult(entries, "missing")).toMatchObject({
      isError: true,
      text: expect.stringContaining('No skill named "missing"')
    })
    expect((await skillsToolResult(entries, "gone")).isError).toBe(true)
  })
})

describe("background failures", () => {
  it("logs the operation and cause", () => {
    const errors = vi.spyOn(console, "error").mockImplementation(() => undefined)
    reportBackgroundFailure("Skill inventory refresh failed", new Error("disk"))
    expect(errors).toHaveBeenCalledWith("Skill inventory refresh failed: disk")
    errors.mockRestore()
  })
})
