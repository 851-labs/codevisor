import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { listProjectGitBranches, worktreeStartPoint } from "./project-branches.js"

const makeRepo = (): { readonly root: string; readonly repo: string } => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-project-branches-"))
  const repo = join(root, "repo")
  mkdirSync(repo)
  execFileSync("git", ["init"], { cwd: repo })
  execFileSync(
    "git",
    ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
    { cwd: repo }
  )
  return { repo, root }
}

describe("project worktree branches", () => {
  it("lists remote branches and resolves an explicitly configured worktree base", async () => {
    const root = mkdtempSync(join(tmpdir(), "codevisor-git-branches-"))
    const origin = join(root, "origin")
    mkdirSync(origin)
    execFileSync("git", ["init", "-b", "main"], { cwd: origin })
    execFileSync(
      "git",
      ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "main"],
      { cwd: origin }
    )
    execFileSync("git", ["branch", "alpha"], { cwd: origin })
    execFileSync("git", ["branch", "release/next"], { cwd: origin })
    const clone = join(root, "clone")
    execFileSync("git", ["clone", origin, clone], { cwd: root })
    execFileSync("git", ["remote", "add", "upstream", origin], { cwd: clone })

    expect(await listProjectGitBranches(clone)).toEqual(
      expect.arrayContaining([
        { remote: "origin", branch: "main", isDefault: true },
        { remote: "origin", branch: "release/next", isDefault: false },
        { remote: "upstream", branch: "alpha", isDefault: false }
      ])
    )
    expect(await worktreeStartPoint(clone, { remote: "origin", branch: "release/next" })).toBe(
      "refs/remotes/origin/release/next"
    )
    await expect(
      worktreeStartPoint(clone, { remote: "origin", branch: "missing" })
    ).rejects.toThrow("Choose another branch in Manage Project")
  })

  it("rejects unavailable remotes and invalid configured branch names", async () => {
    const { repo } = makeRepo()
    await expect(worktreeStartPoint(repo, { remote: "missing", branch: "main" })).rejects.toThrow(
      "remote missing does not exist"
    )

    execFileSync("git", ["remote", "add", "origin", repo], { cwd: repo })
    await expect(
      worktreeStartPoint(repo, { remote: "origin", branch: "invalid..branch" })
    ).rejects.toThrow("is not a valid branch")
  })

  it("ignores cached refs without a matching remote and direct remote HEAD refs", async () => {
    const { repo, root } = makeRepo()
    execFileSync("git", ["update-ref", "refs/remotes/ghost/main", "HEAD"], { cwd: repo })
    expect(await listProjectGitBranches(repo)).toEqual([])

    execFileSync("git", ["remote", "add", "origin", join(root, "missing-origin")], { cwd: repo })
    execFileSync("git", ["update-ref", "refs/remotes/origin/HEAD", "HEAD"], { cwd: repo })
    expect(await listProjectGitBranches(repo)).toEqual([])
  })

  it("uses cached origin/main when refreshing it fails", async () => {
    const root = mkdtempSync(join(tmpdir(), "codevisor-git-offline-"))
    const origin = join(root, "origin")
    mkdirSync(origin)
    execFileSync("git", ["init", "-b", "main"], { cwd: origin })
    execFileSync(
      "git",
      ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
      { cwd: origin }
    )
    const clone = join(root, "clone")
    execFileSync("git", ["clone", origin, clone], { cwd: root })
    execFileSync("git", ["remote", "set-url", "origin", join(root, "missing-origin")], {
      cwd: clone
    })

    expect(await listProjectGitBranches(clone)).toEqual([
      { remote: "origin", branch: "main", isDefault: true }
    ])
    expect(await worktreeStartPoint(clone)).toBe("origin/main")
  })
})
