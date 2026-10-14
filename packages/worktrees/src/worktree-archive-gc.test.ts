import { existsSync, rmSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { makeGitRepo, testTempDir } from "./git-test-support.js"
import { addWorktree, runGit } from "./git.js"
import {
  listSnapshotRefWorktreeIds,
  pruneWorktreeRegistrations,
  removeArchivedWorktreeFiles,
  snapshotWorktree
} from "./worktree-archive.js"

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

    expect([...(await listSnapshotRefWorktreeIds(repo))].toSorted()).toEqual([
      "wt-ramen",
      "wt-sushi"
    ])

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

    rmSync(path, { recursive: true, force: true })
    expect(await registrations()).toBe(true)
    await pruneWorktreeRegistrations(repo)
    expect(await registrations()).toBe(false)

    await expect(
      pruneWorktreeRegistrations(testTempDir(join(root, "not-a-repo-")))
    ).resolves.toBeUndefined()
  })

  it("leaves the snapshot ref behind when only the files are removed", async () => {
    const { repo, root } = makeGitRepo(true)
    const path = join(root, "curry")
    await addWorktree(repo, path, "codevisor/curry")
    await snapshotWorktree(repo, path, "wt-curry")
    const trashed = await removeArchivedWorktreeFiles(repo, path, "codevisor/curry", {
      trashRoot: join(root, ".trash"),
      worktreeId: "wt-curry"
    })

    try {
      expect(existsSync(path)).toBe(false)
      expect(await listSnapshotRefWorktreeIds(repo)).toEqual(["wt-curry"])
    } finally {
      await trashed.purged
    }
  })
})
