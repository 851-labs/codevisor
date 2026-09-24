import { execFileSync } from "node:child_process"
import { rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { makeGitRepo } from "./git-test-support.js"
import { addWorktree } from "./git.js"
import { snapshotWorktree } from "./worktree-archive.js"

const git = (cwd: string, ...args: ReadonlyArray<string>): string =>
  execFileSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], {
    cwd,
    encoding: "utf8"
  }).trim()

const makeWorktree = async (name: string): Promise<{ repo: string; path: string }> => {
  const { repo, root } = makeGitRepo(true)
  const path = join(root, name)
  await addWorktree(repo, path, `codevisor/${name}`)
  return { repo, path }
}

/// The snapshot seeds its scratch index from a copy of the worktree's own
/// index to reuse git's stat cache. That copy is an optimization only: these
/// cases must capture exactly what a snapshot seeded from HEAD would.
describe("snapshot index seeding", () => {
  it("captures the working tree when the worktree has no index to copy", async () => {
    const { repo, path } = await makeWorktree("udon")
    writeFileSync(join(path, "tracked.txt"), "edited\n")
    writeFileSync(join(path, "fresh.txt"), "fresh\n")
    rmSync(git(path, "rev-parse", "--path-format=absolute", "--git-path", "index"))

    const snapshot = await snapshotWorktree(repo, path, "wt-udon")

    expect(git(repo, "show", `${snapshot.snapshotSha}:tracked.txt`)).toBe("edited")
    expect(git(repo, "show", `${snapshot.snapshotSha}:fresh.txt`)).toBe("fresh")
  })

  it("captures edits to files the worktree marked assume-unchanged", async () => {
    // Git skips assume-unchanged entries when it compares stat data, so a
    // copied index carrying that flag would silently drop this edit.
    const { repo, path } = await makeWorktree("pho")
    git(path, "update-index", "--assume-unchanged", "tracked.txt")
    writeFileSync(join(path, "tracked.txt"), "edited\n")

    const snapshot = await snapshotWorktree(repo, path, "wt-pho")

    expect(git(repo, "show", `${snapshot.snapshotSha}:tracked.txt`)).toBe("edited")
  })

  it("snapshots HEAD's tracked set, not what the worktree happened to stage", async () => {
    // Staged state lives only in the real index. The snapshot records the
    // working tree against HEAD, so a force-added ignored file stays out and
    // a file removed from the index but still on disk stays in.
    const { repo, path } = await makeWorktree("bao")
    writeFileSync(join(path, ".gitignore"), "secret.env\n")
    writeFileSync(join(path, "secret.env"), "TOKEN=abc\n")
    git(path, "add", "-f", "secret.env")
    git(path, "rm", "--cached", "--quiet", "tracked.txt")

    const snapshot = await snapshotWorktree(repo, path, "wt-bao")

    const files = git(repo, "ls-tree", "-r", "--name-only", snapshot.snapshotSha).split("\n")
    expect(files.toSorted()).toEqual([".gitignore", "tracked.txt"])
  })
})
