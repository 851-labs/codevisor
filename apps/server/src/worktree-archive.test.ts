import { execFileSync } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"

import { addWorktree, listCodevisorWorktreeBranchNames, removeWorktree, runGit } from "./git.js"
import {
  archiveWorktreeFiles,
  chooseRestoreName,
  deleteSnapshot,
  meaningfulIgnoredPaths,
  releaseBranch,
  restoreWorktree,
  snapshotExists,
  snapshotRefFor,
  snapshotWorktree
} from "./worktree-archive.js"

/// Mirrors the production archive path (snapshot, delete files, release the
/// branch) so tests exercise the same invariants the server relies on.
const archive = (repo: string, path: string, id: string, name: string) =>
  archiveWorktreeFiles(repo, path, id, `codevisor/${name}`, removeWorktree)

const git = (repo: string, ...args: ReadonlyArray<string>): string =>
  execFileSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], {
    cwd: repo,
    encoding: "utf8"
  }).trim()

const makeRepo = (): { readonly root: string; readonly repo: string } => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-archive-"))
  const repo = join(root, "repo")
  mkdirSync(repo)
  git(repo, "init", "-b", "main")
  writeFileSync(join(repo, "tracked.txt"), "original\n")
  git(repo, "add", "-A")
  git(repo, "commit", "-m", "init")
  return { repo, root }
}

/// Builds a worktree carrying every kind of uncommitted state that a naive
/// "delete the files" archive would destroy.
const makeDirtyWorktree = async (repo: string, root: string, name: string): Promise<string> => {
  const path = join(root, name)
  await addWorktree(repo, path, `codevisor/${name}`)
  writeFileSync(join(path, "tracked.txt"), "modified\n")
  writeFileSync(join(path, "untracked.txt"), "new file\n")
  writeFileSync(join(path, "staged.txt"), "staged\n")
  git(path, "add", "staged.txt")
  writeFileSync(join(path, ".gitignore"), "secret.env\nnode_modules/\n")
  git(path, "add", ".gitignore")
  git(path, "commit", "-m", "add gitignore")
  writeFileSync(join(path, "secret.env"), "TOKEN=abc\n")
  mkdirSync(join(path, "node_modules"), { recursive: true })
  writeFileSync(join(path, "node_modules", "junk.js"), "junk\n")
  return path
}

describe("worktree archive snapshots", () => {
  it("round-trips modified, staged, untracked, and deleted files", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "sushi")
    // A tracked file removed from the worktree must come back as a deletion,
    // not silently reappear.
    writeFileSync(join(path, "doomed.txt"), "bye\n")
    git(path, "add", "doomed.txt")
    git(path, "commit", "-m", "add doomed")
    rmSync(join(path, "doomed.txt"))

    const snapshot = await archive(repo, path, "wt-1", "sushi")
    expect(snapshot.snapshotRef).toBe(snapshotRefFor("wt-1"))
    expect(await snapshotExists(repo, snapshot.snapshotRef)).toBe(true)
    expect(existsSync(path)).toBe(false)

    const result = await restoreWorktree({
      repoDir: repo,
      worktreePathFor: (name) => join(root, name),
      originalName: "sushi",
      parentSha: snapshot.parentSha,
      snapshotRef: snapshot.snapshotRef,
      takenNames: new Set()
    })
    const restorePath = join(root, result.name)

    expect(result.restoredFromSnapshot).toBe(true)
    expect(readFileSync(join(restorePath, "tracked.txt"), "utf8")).toBe("modified\n")
    expect(readFileSync(join(restorePath, "untracked.txt"), "utf8")).toBe("new file\n")
    expect(readFileSync(join(restorePath, "staged.txt"), "utf8")).toBe("staged\n")
    expect(existsSync(join(restorePath, "doomed.txt"))).toBe(false)

    // The restored state is uncommitted work, not a commit the user never made.
    expect(git(restorePath, "rev-parse", "HEAD")).toBe(snapshot.parentSha)
    const status = git(restorePath, "status", "--porcelain")
    expect(status).toContain("tracked.txt")
    expect(status).toContain("untracked.txt")
    expect(status).toContain("doomed.txt")
  })

  it("never captures gitignored files but reports the meaningful ones", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "ramen")

    const snapshot = await archive(repo, path, "wt-2", "ramen")

    const restored = await restoreWorktree({
      repoDir: repo,
      worktreePathFor: (name) => join(root, name),
      originalName: "ramen",
      parentSha: snapshot.parentSha,
      snapshotRef: snapshot.snapshotRef,
      takenNames: new Set()
    })
    const restorePath = join(root, restored.name)

    // Secrets and dependency trees stay out of git objects.
    expect(existsSync(join(restorePath, "secret.env"))).toBe(false)
    expect(existsSync(join(restorePath, "node_modules"))).toBe(false)
    // ...but the user is warned about the one that is not regenerable.
    expect(snapshot.ignoredPaths).toContain("secret.env")
    expect(snapshot.ignoredPaths.some((p) => p.includes("node_modules"))).toBe(false)
  })

  it("suffixes the name when the original was reclaimed while archived", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "tacos")
    const snapshot = await archive(repo, path, "wt-3", "tacos")

    // Someone else took `tacos` while this chat sat archived — including the
    // directory, which is the whole point: the restore cannot reuse the
    // original path, so the path has to follow the suffixed name.
    const squatter = join(root, "tacos")
    await addWorktree(repo, squatter, "codevisor/tacos")
    writeFileSync(join(squatter, "stranger.txt"), "not ours\n")

    const result = await restoreWorktree({
      repoDir: repo,
      worktreePathFor: (name) => join(root, name),
      originalName: "tacos",
      parentSha: snapshot.parentSha,
      snapshotRef: snapshot.snapshotRef,
      takenNames: new Set(["tacos"])
    })
    const restorePath = join(root, result.name)

    expect(result.name).toBe("tacos-2")
    expect(result.branch).toBe("codevisor/tacos-2")
    expect(result.restoredFromSnapshot).toBe(true)
    expect(readFileSync(join(restorePath, "tracked.txt"), "utf8")).toBe("modified\n")
    // The squatter's worktree is left completely alone.
    expect(restorePath).not.toBe(squatter)
    expect(existsSync(join(restorePath, "stranger.txt"))).toBe(false)
    expect(readFileSync(join(squatter, "stranger.txt"), "utf8")).toBe("not ours\n")
  })

  it("degrades to a fresh checkout when the snapshot ref is gone", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "curry")
    const snapshot = await archive(repo, path, "wt-4", "curry")

    // The repo was re-cloned or the ref pruned by hand.
    await deleteSnapshot(repo, "wt-4")
    expect(await snapshotExists(repo, snapshot.snapshotRef)).toBe(false)

    const result = await restoreWorktree({
      repoDir: repo,
      worktreePathFor: (name) => join(root, name),
      originalName: "curry",
      parentSha: snapshot.parentSha,
      snapshotRef: snapshot.snapshotRef,
      takenNames: new Set()
    })
    const restorePath = join(root, result.name)

    // Unarchive still succeeds — the chat matters more than the files — but
    // says plainly that the working state could not be recovered.
    expect(result.restoredFromSnapshot).toBe(false)
    expect(existsSync(restorePath)).toBe(true)
    expect(readFileSync(join(restorePath, "tracked.txt"), "utf8")).toBe("original\n")
  })

  it("frees the worktree name by releasing its branch", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "burrito")
    expect(await listCodevisorWorktreeBranchNames(repo)).toContain("burrito")

    await archive(repo, path, "wt-8", "burrito")

    // Worktree names are picked against this namespace too, so a leftover
    // branch would keep the name occupied forever and defeat archiving.
    expect(await listCodevisorWorktreeBranchNames(repo)).not.toContain("burrito")

    // Proof the name is genuinely reusable by an unrelated new worktree.
    const reused = join(root, "burrito-reused")
    await addWorktree(repo, reused, "codevisor/burrito")
    expect(existsSync(reused)).toBe(true)
  })

  it("restores to the original name once it has been freed", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "noodles")
    const snapshot = await archive(repo, path, "wt-9", "noodles")

    const result = await restoreWorktree({
      repoDir: repo,
      worktreePathFor: (name) => join(root, name),
      originalName: "noodles",
      parentSha: snapshot.parentSha,
      snapshotRef: snapshot.snapshotRef,
      takenNames: new Set()
    })

    // The common case: nothing claimed the name, so restore is seamless —
    // same name, same directory the chat had before.
    expect(result.name).toBe("noodles")
    expect(result.restoredFromSnapshot).toBe(true)
    expect(existsSync(join(root, "noodles", "tracked.txt"))).toBe(true)
  })

  it("keeps concurrent archives isolated even with identical ids and commits", async () => {
    // Two separate repos built identically: same content, same second, so git
    // hands both the SAME commit sha. Archiving them concurrently under the
    // same worktree id is the exact case where a scratch index path derived
    // from (id, sha) would collide and let one archive corrupt the other.
    const first = makeRepo()
    const second = makeRepo()
    const firstPath = await makeDirtyWorktree(first.repo, first.root, "udon")
    const secondPath = await makeDirtyWorktree(second.repo, second.root, "udon")
    writeFileSync(join(firstPath, "only-in-first.txt"), "first\n")
    writeFileSync(join(secondPath, "only-in-second.txt"), "second\n")

    const [firstSnapshot, secondSnapshot] = await Promise.all([
      archive(first.repo, firstPath, "same-id", "udon"),
      archive(second.repo, secondPath, "same-id", "udon")
    ])

    const restoredOne = await restoreWorktree({
      repoDir: first.repo,
      worktreePathFor: (name) => join(first.root, name),
      originalName: "udon",
      parentSha: firstSnapshot.parentSha,
      snapshotRef: firstSnapshot.snapshotRef,
      takenNames: new Set()
    })
    const restoreOne = join(first.root, restoredOne.name)
    const restoredTwo = await restoreWorktree({
      repoDir: second.repo,
      worktreePathFor: (name) => join(second.root, name),
      originalName: "udon",
      parentSha: secondSnapshot.parentSha,
      snapshotRef: secondSnapshot.snapshotRef,
      takenNames: new Set()
    })
    const restoreTwo = join(second.root, restoredTwo.name)

    // Each snapshot must contain its own file and not the other's.
    expect(existsSync(join(restoreOne, "only-in-first.txt"))).toBe(true)
    expect(existsSync(join(restoreOne, "only-in-second.txt"))).toBe(false)
    expect(existsSync(join(restoreTwo, "only-in-second.txt"))).toBe(true)
    expect(existsSync(join(restoreTwo, "only-in-first.txt"))).toBe(false)
  })

  it("leaves the user's real index untouched while snapshotting", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "pizza")
    const before = git(path, "status", "--porcelain")

    await snapshotWorktree(repo, path, "wt-5")

    // Archiving must not stage the user's work as a side effect.
    expect(git(path, "status", "--porcelain")).toBe(before)
  })

  it("deletes snapshots idempotently", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "sashimi")
    await snapshotWorktree(repo, path, "wt-6")
    await deleteSnapshot(repo, "wt-6")
    // A second delete (hard-delete after a manual prune) is not an error.
    await expect(deleteSnapshot(repo, "wt-6")).resolves.toBeUndefined()
  })

  it("keeps a snapshot reachable against garbage collection", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "gyoza")
    const snapshot = await archive(repo, path, "wt-7", "gyoza")

    // The ref is the only thing keeping these objects alive once the branch
    // and worktree are gone — an aggressive gc must not collect them.
    git(repo, "reflog", "expire", "--expire=now", "--all")
    git(repo, "gc", "--prune=now", "--quiet")

    expect(await snapshotExists(repo, snapshot.snapshotRef)).toBe(true)
    await expect(
      runGit("cat", ["cat-file", "-e", `${snapshot.snapshotSha}^{commit}`], repo)
    ).resolves.toBeDefined()
  })
})

describe("chooseRestoreName", () => {
  it("prefers the original name and falls back to readable suffixes", () => {
    expect(chooseRestoreName("sushi", new Set())).toBe("sushi")
    expect(chooseRestoreName("sushi", new Set(["sushi"]))).toBe("sushi-2")
    expect(chooseRestoreName("sushi", new Set(["sushi", "sushi-2"]))).toBe("sushi-3")
  })

  it("gives up rather than looping forever when the space is exhausted", () => {
    const taken = new Set(["sushi"])
    for (let index = 2; index <= 99; index += 1) taken.add(`sushi-${String(index)}`)
    expect(chooseRestoreName("sushi", taken)).toBeUndefined()
  })
})

describe("restoreWorktree name exhaustion", () => {
  it("fails loudly rather than restoring under an unrelated name", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "pizza")
    const snapshot = await archive(repo, path, "wt-10", "pizza")

    // Every suffix the restore would consider is already spoken for.
    const taken = new Set(["pizza"])
    for (let index = 2; index <= 99; index += 1) taken.add(`pizza-${String(index)}`)

    await expect(
      restoreWorktree({
        repoDir: repo,
        worktreePathFor: (name) => join(root, name),
        originalName: "pizza",
        parentSha: snapshot.parentSha,
        snapshotRef: snapshot.snapshotRef,
        takenNames: taken
      })
    ).rejects.toThrow(/No available worktree name near pizza/)

    // The snapshot is untouched, so a later restore can still recover it.
    expect(await snapshotExists(repo, snapshot.snapshotRef)).toBe(true)
  })
})

describe("releaseBranch", () => {
  it("reports failure instead of throwing when the branch cannot be deleted", async () => {
    const { repo } = makeRepo()
    // Nothing to delete: releasing is best-effort, and a failure here must not
    // abort an archive that has already removed the worktree.
    expect(await releaseBranch(repo, "codevisor/never-existed")).toBe(false)
  })
})

describe("meaningfulIgnoredPaths", () => {
  it("keeps files worth warning about and drops regenerable output", () => {
    expect(
      meaningfulIgnoredPaths([
        ".env",
        "node_modules/",
        "apps/web/dist/",
        "src/generated.local.json",
        "target/debug/",
        "coverage/"
      ])
    ).toEqual([".env", "src/generated.local.json"])
  })
})
