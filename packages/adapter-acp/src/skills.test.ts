import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { SessionSkillSource } from "@codevisor/api"
import { afterEach, describe, expect, it, vi } from "vitest"

import { acpSkills, discoverSkillFolders, makeAcpSkillTracker } from "./skills.js"

const roots: Array<string> = []

const tempRoot = async (): Promise<string> => {
  const root = await mkdtemp(join(tmpdir(), "acp-skills-"))
  roots.push(root)
  return root
}

const writeSkill = async (dir: string, folder: string, content = "# Skill\n") => {
  await mkdir(join(dir, folder), { recursive: true })
  await writeFile(join(dir, folder, "SKILL.md"), content)
}

afterEach(async () => {
  vi.useRealTimers()
  await Promise.all(roots.splice(0).map((root) => rm(root, { force: true, recursive: true })))
})

describe("ACP skills", () => {
  it("keeps only commands that are skills", () => {
    const folders = new Map<string, SessionSkillSource>([["release", "project"]])
    expect(
      acpSkills(
        [
          { description: "Compact the session", name: "compact" },
          { description: "Cut a release (project skill)", name: "release" },
          {
            _meta: { path: "/repo/.grok/skills/triage/SKILL.md", scope: "repo" },
            description: "Triage CI",
            name: "triage"
          },
          { _meta: { path: "/grok/bundled/docs/SKILL.md", scope: "bundled" }, name: "docs" }
        ],
        folders
      )
    ).toEqual({
      invocationPrefix: "/",
      skills: [
        {
          description: "Cut a release",
          invocation: "/release",
          name: "release",
          source: "project"
        },
        { description: "Triage CI", invocation: "/triage", name: "triage", source: "project" },
        { invocation: "/docs", name: "docs", source: "builtin" }
      ]
    })
  })

  it("finds skill folders in the workspace, its parents, and the home folder", async () => {
    const home = await tempRoot()
    const repo = join(home, "src", "repo")
    const workspace = join(repo, "packages", "app")
    await mkdir(workspace, { recursive: true })
    await writeSkill(join(repo, ".claude", "skills"), "release")
    await writeSkill(join(workspace, ".agents", "skills"), "folder-name", "---\nname: lint\n---\n")
    await writeSkill(join(home, ".cursor", "skills"), "notes")
    // The workspace's own copy shadows the user's.
    await writeSkill(join(home, ".agents", "skills"), "release")
    await mkdir(join(home, ".claude", "skills", "not-a-skill"), { recursive: true })

    expect(Object.fromEntries(await discoverSkillFolders(workspace, home))).toEqual({
      "folder-name": "project",
      lint: "project",
      notes: "user",
      release: "project"
    })
  })

  it("waits briefly for the first command list during session setup", async () => {
    vi.useFakeTimers()
    const tracker = makeAcpSkillTracker(async () => new Map([["release", "project" as const]]))

    const late = tracker.current("session-1", 250)
    const settled = vi.fn()
    void late.then(settled)
    await vi.advanceTimersByTimeAsync(249)
    expect(settled).not.toHaveBeenCalled()
    await tracker.update("session-1", [{ name: "release" }, { name: "compact" }])
    expect(await late).toEqual({
      invocationPrefix: "/",
      skills: [{ invocation: "/release", name: "release", source: "project" }]
    })

    // An agent that never sends one costs only the grace period.
    const missing = tracker.current("session-2", 250)
    await vi.advanceTimersByTimeAsync(250)
    expect(await missing).toBeUndefined()
  })

  it("reports a list only when it changed", async () => {
    const tracker = makeAcpSkillTracker(async () => new Map([["release", "project" as const]]))
    expect(await tracker.update("s", [{ name: "release" }])).toBeDefined()
    expect(await tracker.update("s", [{ name: "release" }, { name: "compact" }])).toBeUndefined()
  })
})
