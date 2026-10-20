import { chmodSync, existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import { describe, expect, it, onTestFinished, vi } from "vitest"

import { makeGitRepo } from "./git-test-support.js"
import { addWorktree, listCodevisorWorktreeBranchNames, runGit } from "./git.js"
import { removeArchivedWorktreeFiles } from "./worktree-archive.js"
import {
  makeTrashQueue,
  sweepWorktreeTrash,
  type TrashCommandRunner,
  trashDirectory,
  trashWorktree
} from "./worktree-trash.js"

interface HeldCommand {
  readonly command: string
  readonly args: ReadonlyArray<string>
  readonly finish: (failure?: Error) => void
}

const heldCommands = () => {
  const started: Array<HeldCommand> = []
  const waiting: Array<() => void> = []
  const run: TrashCommandRunner = (command, args) =>
    new Promise((resolve, reject) => {
      started.push({
        command,
        args,
        finish: (failure) => (failure === undefined ? resolve() : reject(failure))
      })
      for (const wake of waiting.splice(0)) wake()
    })
  const startedCount = async (count: number): Promise<void> => {
    while (started.length < count) await new Promise<void>((resolve) => waiting.push(resolve))
  }
  return { run, started, startedCount }
}

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

    expect(existsSync(path)).toBe(false)
    expect(await registered(repo, path)).toBe(false)
    expect(await listCodevisorWorktreeBranchNames(repo)).toEqual([])
    expect(readdirSync(trashRoot)).toContain(".metadata_never_index")

    await trashed.purged
    expect(readdirSync(trashRoot)).toEqual([".metadata_never_index"])
  })

  it("still releases the branch when the directory is already gone", async () => {
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

  it("deletes one entry at a time at normal priority, moving past a failure", async () => {
    const { run, started, startedCount } = heldCommands()
    const log = vi.fn()
    const queue = makeTrashQueue(run, log)

    const first = queue.enqueue("/trash/wt-1")
    const second = queue.enqueue("/trash/wt-2")
    await startedCount(1)
    expect(started.map(({ command, args }) => [command, ...args])).toEqual([
      ["/bin/rm", "-rf", "--", "/trash/wt-1"]
    ])

    started[0]?.finish(new Error("Operation not permitted"))
    await first
    expect(log).toHaveBeenCalledWith(
      "Couldn't delete trashed /trash/wt-1: Error: Operation not permitted"
    )
    await startedCount(2)
    expect(started[1]?.args).toEqual(["-rf", "--", "/trash/wt-2"])
    started[1]?.finish()
    await second
  })

  it("deletes a path queued twice only once", async () => {
    const { run, started, startedCount } = heldCommands()
    const queue = makeTrashQueue(run, vi.fn())

    const first = queue.enqueue("/trash/wt-1")
    const again = queue.enqueue("/trash/wt-1")
    await startedCount(1)
    started[0]?.finish()
    await Promise.all([first, again])

    const later = queue.enqueue("/trash/wt-1")
    await startedCount(2)
    started[1]?.finish()
    await later
    expect(started.map(({ args }) => args.at(-1))).toEqual(["/trash/wt-1", "/trash/wt-1"])
  })

  it("logs an entry it cannot delete and still clears the rest of the trash", async () => {
    const { root } = makeGitRepo()
    const trashRoot = join(root, ".trash")
    const locked = join(trashRoot, "wt-locked", "sealed")
    mkdirSync(locked, { recursive: true })
    writeFileSync(join(locked, "file"), "x")
    chmodSync(locked, 0o500)
    onTestFinished(() => chmodSync(locked, 0o700))
    mkdirSync(join(trashRoot, "wt-open"))
    const logged = vi.spyOn(console, "error").mockImplementation(() => undefined)
    onTestFinished(() => logged.mockRestore())

    await sweepWorktreeTrash(trashRoot)

    expect(readdirSync(trashRoot)).toEqual(["wt-locked"])
    expect(logged).toHaveBeenCalledWith(
      expect.stringContaining(`Couldn't delete trashed ${join(trashRoot, "wt-locked")}`)
    )
  })
})
