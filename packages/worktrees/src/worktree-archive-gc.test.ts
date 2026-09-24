import { existsSync, rmSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { makeGitRepo, testTempDir } from "./git-test-support.js"
import { addWorktree, removeWorktree, runGit } from "./git.js"
import {
  listSnapshotRefWorktreeIds,
  pruneWorktreeRegistrations,
  removeArchivedWorktreeFiles,
  snapshotWorktree
} from "./worktree-archive.js"

/// The inputs a garbage-collection pass needs: which snapshot refs exist, and
/// which worktree registrations git is still holding. Both are deliberately
/// forgiving — housekeeping must never be the thing that fails a boot.
describe("worktree archive garbage collection", () => {
  it("lists snapshot refs by worktree id and ignores repositories it cannot read", async () => {
    const { repo, root } = makeGitRepo(true)
    expect(await listSnapshotRefWorktreeIds(repo)).toEqual([])

    const first = join(root, "sushi")
    await addWorktree(repo, first, "codevisor/sushi")
    await snapshotWorktree(repo, first, "wt-sushi")
    const second = join(root, "ramen")
    await addWorktree(repo, second, "codevisor/ramen")
    await snapshotWorktree(repo, second, "wt-ramen")

    // Keyed by worktree id, never by name: archiving frees the name, so only
    // the id can still identify a snapshot.
    expect([...(await listSnapshotRefWorktreeIds(repo))].sort()).toEqual(["wt-ramen", "wt-sushi"])

    // A path that is not a repository is not something to prune.
    expect(await listSnapshotRefWorktreeIds(testTempDir(join(root, "not-a-repo-")))).toEqual([])
  })

  it("prunes registrations left by a directory that vanished, and tolerates failure", async () => {
    const { repo, root } = makeGitRepo(true)
    const path = join(root, "tacos")
    await addWorktree(repo, path, "codevisor/tacos")
    const registrations = () =>
      runGit("worktree-list", ["worktree", "list", "--porcelain"], repo).then((output) =>
        output.includes(path)
      )
    expect(await registrations()).toBe(true)

    // The directory disappears without git being told — a crash between
    // deleting files and recording the archive leaves exactly this.
    rmSync(path, { recursive: true, force: true })
    expect(await registrations()).toBe(true)
    await pruneWorktreeRegistrations(repo)
    expect(await registrations()).toBe(false)

    // Housekeeping against a non-repository resolves rather than throwing.
    await expect(
      pruneWorktreeRegistrations(testTempDir(join(root, "not-a-repo-")))
    ).resolves.toBeUndefined()
  })

  it("leaves the snapshot ref behind when only the files are removed", async () => {
    // `removeArchivedWorktreeFiles` is the destructive half on its own: the
    // snapshot must survive it, because the caller records the archive between
    // the two steps and an interruption has to stay recoverable.
    const { repo, root } = makeGitRepo(true)
    const path = join(root, "curry")
    await addWorktree(repo, path, "codevisor/curry")
    await snapshotWorktree(repo, path, "wt-curry")
    await removeArchivedWorktreeFiles(repo, path, "codevisor/curry", removeWorktree)

    expect(existsSync(path)).toBe(false)
    expect(await listSnapshotRefWorktreeIds(repo)).toEqual(["wt-curry"])
  })
})
