import { execFileSync } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"

import { describe, expect, it, vi } from "vitest"

import { makeGitRepo } from "./git-test-support.js"
import { addWorktree, listCodevisorWorktreeBranchNames, runGit } from "./git.js"
import {
  chooseRestoreName,
  deleteSnapshot,
  releaseBranch,
  removeArchivedWorktreeFiles,
  restoreWorktree,
  snapshotExists,
  snapshotRefFor,
  snapshotWorktree
} from "./worktree-archive.js"

const archive = async (repo: string, path: string, id: string, name: string) => {
  const snapshot = await snapshotWorktree(repo, path, id)
  const trashed = await removeArchivedWorktreeFiles(repo, path, `codevisor/${name}`, {
    trashRoot: join(dirname(path), ".trash"),
    worktreeId: id
  })
  await trashed.purged
  return snapshot
}

const git = (repo: string, ...args: ReadonlyArray<string>): string =>
  execFileSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], {
    cwd: repo,
    encoding: "utf8"
  }).trim()

const makeRepo = () => makeGitRepo(true)

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

    expect(git(restorePath, "rev-parse", "HEAD")).toBe(snapshot.parentSha)
    const status = git(restorePath, "status", "--porcelain")
    expect(status).toContain("tracked.txt")
    expect(status).toContain("untracked.txt")
    expect(status).toContain("doomed.txt")
  })

  it("never captures gitignored files in the snapshot", async () => {
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

    expect(existsSync(join(restorePath, "secret.env"))).toBe(false)
    expect(existsSync(join(restorePath, "node_modules"))).toBe(false)
  })

  it("suffixes the name when the original was reclaimed while archived", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "tacos")
    const snapshot = await archive(repo, path, "wt-3", "tacos")

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
    expect(restorePath).not.toBe(squatter)
    expect(existsSync(join(restorePath, "stranger.txt"))).toBe(false)
    expect(readFileSync(join(squatter, "stranger.txt"), "utf8")).toBe("not ours\n")
  })

  it("degrades to a fresh checkout when the snapshot ref is gone", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "curry")
    const snapshot = await archive(repo, path, "wt-4", "curry")

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

    expect(result.restoredFromSnapshot).toBe(false)
    expect(existsSync(restorePath)).toBe(true)
    expect(readFileSync(join(restorePath, "tracked.txt"), "utf8")).toBe("original\n")
  })

  it("frees the worktree name by releasing its branch", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "burrito")
    expect(await listCodevisorWorktreeBranchNames(repo)).toContain("burrito")

    await archive(repo, path, "wt-8", "burrito")

    expect(await listCodevisorWorktreeBranchNames(repo)).not.toContain("burrito")

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

    expect(result.name).toBe("noodles")
    expect(result.restoredFromSnapshot).toBe(true)
    expect(existsSync(join(root, "noodles", "tracked.txt"))).toBe(true)
  })

  it("keeps concurrent archives isolated even with identical ids and commits", async () => {
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

    expect(git(path, "status", "--porcelain")).toBe(before)
  })

  it("deletes snapshots idempotently", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "sashimi")
    await snapshotWorktree(repo, path, "wt-6")
    await deleteSnapshot(repo, "wt-6")
    await expect(deleteSnapshot(repo, "wt-6")).resolves.toBeUndefined()
  })

  it("keeps a snapshot reachable against garbage collection", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "gyoza")
    const snapshot = await archive(repo, path, "wt-7", "gyoza")

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
})

describe("snapshot identity", () => {
  it("archives on a machine with no git identity configured", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "gnocchi")

    const identityless: NodeJS.ProcessEnv = {
      ...process.env,
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_SYSTEM: "/dev/null",
      GIT_AUTHOR_NAME: undefined,
      GIT_AUTHOR_EMAIL: undefined,
      GIT_COMMITTER_NAME: undefined,
      GIT_COMMITTER_EMAIL: undefined
    }

    const snapshot = await snapshotWorktree(repo, path, "wt-11", identityless)
    expect(await snapshotExists(repo, snapshot.snapshotRef, identityless)).toBe(true)

    const author = execFileSync("git", ["show", "-s", "--format=%an <%ae>", snapshot.snapshotSha], {
      cwd: repo,
      encoding: "utf8",
      env: identityless
    }).trim()
    expect(author).toBe("Codevisor <noreply@codevisor.app>")
  })
})

describe("restoreWorktree name exhaustion", () => {
  it("fails loudly rather than restoring under an unrelated name", async () => {
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "pizza")
    const snapshot = await archive(repo, path, "wt-10", "pizza")

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

    expect(await snapshotExists(repo, snapshot.snapshotRef)).toBe(true)
  })
})

describe("releaseBranch", () => {
  it("reports failure instead of throwing when the branch cannot be deleted", async () => {
    const { repo } = makeRepo()
    expect(await releaseBranch(repo, "codevisor/never-existed")).toBe(false)
  })
})

describe("restoreWorktree git environment", () => {
  it("scans taken branch names with the caller's environment", async () => {
    const env = { ...process.env }
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "ramen")
    const snapshot = await archive(repo, path, "wt-12", "ramen")
    await addWorktree(repo, join(root, "squat-1"), "codevisor/ramen")
    await addWorktree(repo, join(root, "squat-2"), "codevisor/ramen-2")

    vi.stubEnv("PATH", "")
    const restored = await restoreWorktree({
      repoDir: repo,
      worktreePathFor: (name) => join(root, name),
      originalName: "ramen",
      parentSha: snapshot.parentSha,
      snapshotRef: snapshot.snapshotRef,
      takenNames: new Set(),
      env
    })

    expect(restored).toMatchObject({ name: "ramen-3", restoredFromSnapshot: true })
  })

  it("looks up the fresh start point with the caller's environment", async () => {
    const env = { ...process.env }
    const { repo, root } = makeRepo()
    const path = await makeDirtyWorktree(repo, root, "pho")
    const snapshot = await archive(repo, path, "wt-13", "pho")
    await deleteSnapshot(repo, "wt-13")
    git(repo, "update-ref", "refs/remotes/origin/main", "main")

    vi.stubEnv("PATH", "")
    const fresh = await restoreWorktree({
      repoDir: repo,
      worktreePathFor: (name) => join(root, name),
      originalName: "pho",
      parentSha: snapshot.parentSha,
      snapshotRef: snapshot.snapshotRef,
      takenNames: new Set(),
      env
    })

    expect(fresh).toMatchObject({ name: "pho", restoredFromSnapshot: false })
    expect(existsSync(join(root, "pho", ".gitignore"))).toBe(false)
  })
})
