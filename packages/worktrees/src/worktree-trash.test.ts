import { existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { makeGitRepo } from "./git-test-support.js"
import { addWorktree, listCodevisorWorktreeBranchNames, runGit } from "./git.js"
import { removeArchivedWorktreeFiles } from "./worktree-archive.js"
import {
  diskSpace,
  LOW_DISK_FREE_BYTES,
  purgePriority,
  sweepWorktreeTrash,
  trashDirectory,
  trashWorktree
} from "./worktree-trash.js"

const registered = async (repo: string, path: string): Promise<boolean> =>
  (await runGit("worktree-list", ["worktree", "list", "--porcelain"], repo)).includes(path)

describe("worktree trash", () => {
  it("moves the files aside, releases the branch, then deletes the files", async () => {
    const { repo, root } = makeGitRepo(true)
    const path = join(root, "sushi")
    await addWorktree(repo, path, "codevisor/sushi")
    mkdirSync(join(path, "node_modules", "pkg"), { recursive: true })
    writeFileSync(join(path, "node_modules", "pkg", "index.js"), "junk\n")
    const trashRoot = join(root, ".trash")

    const trashed = await removeArchivedWorktreeFiles(repo, path, "codevisor/sushi", {
      trashRoot,
      worktreeId: "wt-sushi"
    })

    // The path, its registration, and its branch are free before any file is
    // deleted, so a restore or a new worktree can take the name at once.
    expect(existsSync(path)).toBe(false)
    expect(await registered(repo, path)).toBe(false)
    expect(await listCodevisorWorktreeBranchNames(repo)).toEqual([])
    // Spotlight is told to skip the trash.
    expect(readdirSync(trashRoot)).toContain(".metadata_never_index")

    await trashed.purged
    expect(readdirSync(trashRoot)).toEqual([".metadata_never_index"])
  })

  it("still releases the branch when the directory is already gone", async () => {
    // A crash after the files were moved but before the branch was released
    // leaves exactly this; the name must not stay occupied forever.
    const { repo, root } = makeGitRepo(true)
    const path = join(root, "ramen")
    await addWorktree(repo, path, "codevisor/ramen")
    rmSync(path, { recursive: true, force: true })

    const trashed = await removeArchivedWorktreeFiles(repo, path, "codevisor/ramen", {
      trashRoot: join(root, ".trash"),
      worktreeId: "wt-ramen"
    })
    await trashed.purged

    expect(await registered(repo, path)).toBe(false)
    expect(await listCodevisorWorktreeBranchNames(repo)).toEqual([])
  })

  it("has git delete the files in place when the trash cannot be used", async () => {
    const { repo, root } = makeGitRepo(true)
    const path = join(root, "curry")
    await addWorktree(repo, path, "codevisor/curry")
    // A file where the trash directory belongs makes the move impossible.
    const trashRoot = join(root, "blocked")
    writeFileSync(trashRoot, "")

    const trashed = await trashWorktree(repo, path, { trashRoot, id: "wt-curry" })
    await trashed.purged

    expect(existsSync(path)).toBe(false)
    expect(await registered(repo, path)).toBe(false)
  })

  it("propagates a failure to remove the files at all", async () => {
    const { repo, root } = makeGitRepo(true)
    const trashRoot = join(root, "blocked")
    writeFileSync(trashRoot, "")
    const unregistered = join(root, "stranger")
    mkdirSync(unregistered)

    // Not a worktree git knows about, so the fallback refuses to touch it.
    await expect(
      trashWorktree(repo, unregistered, { trashRoot, id: "wt-stranger" })
    ).rejects.toThrow()
    expect(existsSync(unregistered)).toBe(true)
  })

  it("trashes a plain directory, deleting in place when the trash cannot be used", async () => {
    const { root } = makeGitRepo()
    const moved = join(root, "project-a")
    mkdirSync(join(moved, "src"), { recursive: true })
    writeFileSync(join(moved, "src", "index.ts"), "x")
    const trashRoot = join(root, ".trash")

    const trashed = await trashDirectory(moved, { trashRoot, id: "project-a" })
    expect(existsSync(moved)).toBe(false)
    await trashed.purged
    expect(readdirSync(trashRoot)).toEqual([".metadata_never_index"])

    const inPlace = join(root, "project-b")
    mkdirSync(inPlace)
    const blocked = join(root, "blocked")
    writeFileSync(blocked, "")
    await (
      await trashDirectory(inPlace, { trashRoot: blocked, id: "project-b" })
    ).purged
    expect(existsSync(inPlace)).toBe(false)

    await (
      await trashDirectory(join(root, "missing"), { trashRoot, id: "missing" })
    ).purged
  })

  it("sweeps what an earlier run left behind and tolerates a missing trash", async () => {
    const { root } = makeGitRepo()
    const trashRoot = join(root, ".trash")
    await sweepWorktreeTrash(trashRoot)

    mkdirSync(join(trashRoot, "wt-1-abc", "deep"), { recursive: true })
    writeFileSync(join(trashRoot, "wt-1-abc", "deep", "file"), "x")
    writeFileSync(join(trashRoot, ".metadata_never_index"), "")
    await sweepWorktreeTrash(trashRoot)

    expect(readdirSync(trashRoot)).toEqual([".metadata_never_index"])
  })

  it("deletes at background priority unless the disk is running low", () => {
    const gib = 1024 ** 3
    // Plenty of room: nobody is waiting on the delete.
    expect(purgePriority({ free: 200 * gib, total: 500 * gib })).toBe("background")
    // Low in absolute terms, or as a share of a large disk: the space is needed now.
    expect(purgePriority({ free: LOW_DISK_FREE_BYTES - 1, total: 100 * gib })).toBe("utility")
    expect(purgePriority({ free: 40 * gib, total: 500 * gib })).toBe("utility")
    // Unknown free space keeps the polite default.
    expect(purgePriority(undefined)).toBe("background")
  })

  it("reads the volume's free space, or nothing for a path that is gone", async () => {
    const { repo } = makeGitRepo()
    const space = await diskSpace(repo)
    expect(space?.total).toBeGreaterThan(0)
    expect(space?.free).toBeLessThanOrEqual(space?.total ?? 0)
    expect(await diskSpace(join(repo, "missing"))).toBeUndefined()
  })
})
