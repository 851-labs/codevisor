import { homedir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import {
  managedRepoPath,
  managedReposRoot,
  scratchWorkspacePath,
  scratchWorkspacesRoot
} from "./index.js"

describe("@codevisor/db", () => {
  it("derives managed repo paths from the canonical repos root", () => {
    const previous = process.env["CODEVISOR_REPOS_ROOT"]
    delete process.env["CODEVISOR_REPOS_ROOT"]
    expect(managedReposRoot()).toBe(join(homedir(), ".codevisor", "repos"))
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
})
