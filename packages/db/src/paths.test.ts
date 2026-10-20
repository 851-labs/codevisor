import { mkdirSync, mkdtempSync, rmSync } from "node:fs"
import { homedir, tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import {
  botPath,
  isBotFolder,
  legacyWorktreeTrashRoot,
  managedRepoPath,
  scratchWorkspacePath,
  scratchWorkspacesRoot,
  worktreeNameAt,
  worktreePath,
  worktreePathBeside,
  worktreeTrashRoot
} from "./index.js"

const withWorktreesRoot = (body: (root: string) => void): void => {
  const previous = process.env["CODEVISOR_WORKTREES_ROOT"]
  const root = mkdtempSync(join(tmpdir(), "codevisor-paths-"))
  process.env["CODEVISOR_WORKTREES_ROOT"] = root
  try {
    body(root)
  } finally {
    if (previous === undefined) delete process.env["CODEVISOR_WORKTREES_ROOT"]
    else process.env["CODEVISOR_WORKTREES_ROOT"] = previous
    rmSync(root, { recursive: true, force: true })
  }
}

describe("@codevisor/db", () => {
  it("derives managed repo paths from the canonical repos root", () => {
    const previous = process.env["CODEVISOR_REPOS_ROOT"]
    delete process.env["CODEVISOR_REPOS_ROOT"]
    expect(managedRepoPath("my-repo")).toBe(join(homedir(), ".codevisor", "repos", "my-repo"))
    process.env["CODEVISOR_REPOS_ROOT"] = "/tmp/custom-repos"
    expect(managedRepoPath("my-repo")).toBe("/tmp/custom-repos/my-repo")
    if (previous === undefined) {
      delete process.env["CODEVISOR_REPOS_ROOT"]
    } else {
      process.env["CODEVISOR_REPOS_ROOT"] = previous
    }
  })

  it("derives scratch workspace paths beside the worktrees root", () => {
    const previous = process.env["CODEVISOR_WORKTREES_ROOT"]
    delete process.env["CODEVISOR_WORKTREES_ROOT"]
    expect(scratchWorkspacesRoot()).toBe(join(homedir(), "codevisor", "workspaces"))
    process.env["CODEVISOR_WORKTREES_ROOT"] = "/tmp/custom-worktrees"
    expect(scratchWorkspacePath("meatball")).toBe("/tmp/custom-worktrees/workspaces/meatball")
    if (previous === undefined) {
      delete process.env["CODEVISOR_WORKTREES_ROOT"]
    } else {
      process.env["CODEVISOR_WORKTREES_ROOT"] = previous
    }
  })

  it("puts new worktrees under a .noindex folder and keeps existing ones where they are", () => {
    withWorktreesRoot((root) => {
      const unindexed = join(root, "worktrees.noindex", "project-a", "sushi")
      expect(worktreePath("project-a", "sushi")).toBe(unindexed)
      expect(worktreeNameAt("project-a", unindexed)).toBe("sushi")
      expect(worktreePathBeside("project-a", unindexed, "sushi-2")).toBe(
        join(root, "worktrees.noindex", "project-a", "sushi-2")
      )

      const legacy = join(root, "project-a", "ramen")
      mkdirSync(legacy, { recursive: true })
      expect(worktreePath("project-a", "ramen")).toBe(legacy)
      expect(worktreeNameAt("project-a", legacy)).toBe("ramen")
      expect(worktreePathBeside("project-a", legacy, "ramen-2")).toBe(
        join(root, "project-a", "ramen-2")
      )

      expect(worktreeNameAt("project-a", join(root, "project-b", "ramen"))).toBeUndefined()
      expect(worktreeTrashRoot()).toBe(join(root, ".trash.noindex"))
      expect(legacyWorktreeTrashRoot()).toBe(join(root, ".trash"))
      expect(worktreeTrashRoot()).toBe(join(root, ".trash.noindex"))
      expect(legacyWorktreeTrashRoot()).toBe(join(root, ".trash"))
    })
  })

  it("puts new bot folders under a .noindex folder and keeps existing ones where they are", () => {
    withWorktreesRoot((root) => {
      expect(botPath("scout")).toBe(join(root, "bots.noindex", "scout"))
      mkdirSync(join(root, "bots", "herald"), { recursive: true })
      expect(botPath("herald")).toBe(join(root, "bots", "herald"))
      expect(isBotFolder(botPath("scout"))).toBe(true)
      expect(isBotFolder(botPath("herald"))).toBe(true)
      expect(isBotFolder(join(root, "workspaces", "scout"))).toBe(false)
    })
  })
})
