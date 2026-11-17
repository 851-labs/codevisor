import { execFileSync } from "node:child_process"
import { mkdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { testTempDir } from "./git-test-support.js"
import { GitError } from "./git.js"
import { restoreSavedWork, saveWork } from "./saved-work.js"

const git = (cwd: string, ...args: ReadonlyArray<string>): string =>
  execFileSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], {
    cwd,
    stdio: ["ignore", "pipe", "ignore"]
  })
    .toString()
    .trimEnd()

const originWithClone = () => {
  const root = testTempDir(join(tmpdir(), "codevisor-saved-work-"))
  const origin = join(root, "origin")
  mkdirSync(origin)
  git(origin, "init", "-b", "main")
  writeFileSync(join(origin, "kept.txt"), "original\n")
  writeFileSync(join(origin, "removed.txt"), "going away\n")
  git(origin, "add", ".")
  git(origin, "commit", "-m", "init")
  const cloneAs = (name: string): string => {
    git(root, "clone", `file://${origin}`, join(root, name))
    return join(root, name)
  }
  return { origin, cloneAs }
}

const workedOn = (clone: string): void => {
  git(clone, "checkout", "-b", "codevisor/pear")
  git(clone, "commit", "--allow-empty", "-m", "never pushed")
  writeFileSync(join(clone, "kept.txt"), "edited\n")
  writeFileSync(join(clone, "new.txt"), "untracked\n")
  rmSync(join(clone, "removed.txt"))
}

describe("work saved from a checkout", () => {
  it("comes back in a fresh clone: branch, unpushed commits, and uncommitted changes", async () => {
    const { cloneAs } = originWithClone()
    const first = cloneAs("first")
    workedOn(first)

    const saved = await saveWork(first)
    const second = cloneAs("second")
    await restoreSavedWork(second, saved)

    expect(saved.branch).toBe("codevisor/pear")
    expect(git(second, "branch", "--show-current")).toBe("codevisor/pear")
    expect(git(second, "log", "-1", "--format=%s")).toBe("never pushed")
    expect(git(second, "rev-parse", "HEAD")).toBe(git(first, "rev-parse", "HEAD"))
    expect(git(second, "status", "--porcelain")).toBe(git(first, "status", "--porcelain"))
    expect(git(second, "status", "--porcelain").split("\n")).toEqual([
      " M kept.txt",
      " D removed.txt",
      "?? new.txt"
    ])
  })

  it("refuses to restore onto a clone that lacks the commits the work was built on", async () => {
    const { origin, cloneAs } = originWithClone()
    const first = cloneAs("first")
    workedOn(first)
    const saved = await saveWork(first)
    git(origin, "checkout", "--orphan", "rewritten")
    git(origin, "commit", "--allow-empty", "-m", "history replaced")
    git(origin, "branch", "-D", "main")
    git(origin, "branch", "-m", "main")

    const second = cloneAs("second")
    const failure = await restoreSavedWork(second, saved).catch((cause: unknown) => cause)

    expect(failure).toBeInstanceOf(GitError)
    expect(git(second, "branch", "--show-current")).toBe("main")
  })
})
