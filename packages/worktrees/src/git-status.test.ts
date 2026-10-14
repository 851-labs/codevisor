import { execFileSync } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { gitDiff } from "./git-review.js"
import { gitDiscard, gitStage, gitStatus, gitUnstage, parseGitStatus } from "./git-status.js"
import { makeGitRepo, testTempDir } from "./git-test-support.js"

const git = (cwd: string, ...args: ReadonlyArray<string>): string =>
  execFileSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], {
    cwd,
    encoding: "utf8"
  }).trim()

const write = (repo: string, path: string, content: string): void =>
  writeFileSync(join(repo, path), content)

/// A repository with three committed files, one in a folder with a space.
/// Edits below change each file's size: an edit within the commit's second
/// that keeps the size can look unchanged to a copied index (racy git).
const committedRepo = (): string => {
  const { repo } = makeGitRepo()
  mkdirSync(join(repo, "src dir"))
  write(repo, "edit.txt", "one\n")
  write(repo, "gone.txt", "gone\n")
  write(repo, "src dir/old.txt", "moved\n")
  git(repo, "add", "-A")
  git(repo, "commit", "-q", "-m", "files")
  return repo
}

describe("parseGitStatus", () => {
  it("reads conflicts, type changes, renames, and a detached HEAD", () => {
    const output = [
      "# branch.oid 0123abc",
      "# branch.head (detached)",
      "1 .T N... 100644 100644 120000 aaa aaa link",
      "2 RM N... 100644 100644 100644 aaa bbb R90 new name.txt",
      "old name.txt",
      "u UU N... 100644 100644 100644 100644 aaa bbb ccc both changed.txt",
      "? scratch.txt",
      ""
    ].join("\0")

    expect(parseGitStatus(output)).toEqual({
      branch: null,
      entries: [
        { path: "link", unstaged: "typeChanged" },
        { path: "new name.txt", oldPath: "old name.txt", staged: "renamed", unstaged: "modified" },
        { path: "both changed.txt", unstaged: "conflicted" },
        { path: "scratch.txt", unstaged: "untracked" }
      ]
    })
  })
})

describe("gitStatus", () => {
  it("classifies staged, unstaged, untracked, renamed, and deleted files from any folder", async () => {
    const repo = committedRepo()
    write(repo, "edit.txt", "edited twice\n")
    git(repo, "add", "edit.txt")
    write(repo, "edit.txt", "three\n")
    rmSync(join(repo, "gone.txt"))
    renameSync(join(repo, "src dir/old.txt"), join(repo, "src dir/new.txt"))
    git(repo, "add", "-A", "src dir")
    write(repo, "src dir/fresh *.txt", "new\n")

    const status = await gitStatus(join(repo, "src dir"))

    expect(status.repositoryRoot).toBe(git(repo, "rev-parse", "--show-toplevel"))
    expect(status.branch).toBe("main")
    expect(status.truncated).toBe(false)
    expect(status.entries).toEqual([
      { path: "edit.txt", staged: "modified", unstaged: "modified" },
      { path: "gone.txt", unstaged: "deleted" },
      { path: "src dir/new.txt", oldPath: "src dir/old.txt", staged: "renamed" },
      { path: "src dir/fresh *.txt", unstaged: "untracked" }
    ])
  })

  it("rejects a folder outside any repository", async () => {
    await expect(gitStatus(testTempDir(join(tmpdir(), "codevisor-status-")))).rejects.toMatchObject(
      {
        code: "not_git_repository"
      }
    )
  })
})

describe("staging", () => {
  it("stages and unstages single files and everything, literally by name", async () => {
    const repo = committedRepo()
    write(repo, "edit.txt", "edited twice\n")
    write(repo, "*.txt", "a file named star\n")
    rmSync(join(repo, "gone.txt"))

    const staged = await gitStage(repo, ["*.txt", "gone.txt"])
    expect(staged.entries).toEqual([
      { path: "*.txt", staged: "added" },
      { path: "edit.txt", unstaged: "modified" },
      { path: "gone.txt", staged: "deleted" }
    ])

    const unstaged = await gitUnstage(repo, ["gone.txt"])
    expect(unstaged.entries.find((entry) => entry.path === "gone.txt")).toEqual({
      path: "gone.txt",
      unstaged: "deleted"
    })

    expect((await gitStage(repo)).entries.every((entry) => entry.unstaged === undefined)).toBe(true)
    expect((await gitUnstage(repo)).entries.every((entry) => entry.staged === undefined)).toBe(true)
  })

  it("unstages before the first commit", async () => {
    const { repo } = makeGitRepo()
    git(repo, "update-ref", "-d", "HEAD")
    write(repo, "first.txt", "first\n")
    await gitStage(repo)

    write(repo, "second.txt", "second\n")
    await gitStage(repo)

    expect((await gitUnstage(repo, ["first.txt"])).entries).toEqual([
      { path: "second.txt", staged: "added" },
      { path: "first.txt", unstaged: "untracked" }
    ])
    expect((await gitUnstage(repo)).entries).toEqual([
      { path: "first.txt", unstaged: "untracked" },
      { path: "second.txt", unstaged: "untracked" }
    ])
  })
})

describe("gitDiscard", () => {
  it("restores tracked files to their staged content and deletes untracked ones", async () => {
    const repo = committedRepo()
    write(repo, "edit.txt", "staged\n")
    git(repo, "add", "edit.txt")
    write(repo, "edit.txt", "unstaged\n")
    rmSync(join(repo, "gone.txt"))
    write(repo, "scratch.txt", "scratch\n")

    const status = await gitDiscard(repo, ["edit.txt", "gone.txt", "scratch.txt"])

    expect(readFileSync(join(repo, "edit.txt"), "utf8")).toBe("staged\n")
    expect(readFileSync(join(repo, "gone.txt"), "utf8")).toBe("gone\n")
    expect(existsSync(join(repo, "scratch.txt"))).toBe(false)
    expect(status.entries).toEqual([{ path: "edit.txt", staged: "modified" }])
  })

  it("discards only what it is given, and nothing for no files", async () => {
    const repo = committedRepo()
    write(repo, "edit.txt", "edited twice\n")
    write(repo, "scratch.txt", "scratch\n")

    expect((await gitDiscard(repo, [])).entries).toHaveLength(2)
    expect((await gitDiscard(repo, ["scratch.txt"])).entries).toEqual([
      { path: "edit.txt", unstaged: "modified" }
    ])
    expect((await gitDiscard(repo, ["edit.txt"])).entries).toEqual([])
  })
})

describe("gitDiff paths", () => {
  it("compares only the requested file, relative to the repository root", async () => {
    const repo = committedRepo()
    write(repo, "edit.txt", "edited twice\n")
    write(repo, "src dir/old.txt", "changed\n")

    const diff = await gitDiff(join(repo, "src dir"), "unstaged", { paths: ["edit.txt"] })

    expect(diff.files.map((file) => file.path)).toEqual(["edit.txt"])
  })
})
