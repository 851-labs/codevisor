import { execFileSync } from "node:child_process"
import { readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { GitDiffFile, GitDiffMode } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { gitDiff, gitRefs, recordTurnStartSnapshot } from "./git-review.js"
import { makeGitRepo, testTempDir } from "./git-test-support.js"

const git = (cwd: string, ...args: ReadonlyArray<string>): string =>
  execFileSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], {
    cwd,
    encoding: "utf8"
  }).trim()

const write = (repo: string, path: string, content: string | Buffer): void =>
  writeFileSync(join(repo, path), content)

const indexBytes = (repo: string): Buffer =>
  readFileSync(git(repo, "rev-parse", "--path-format=absolute", "--git-path", "index"))

const anyFingerprint: string = expect.stringMatching(/^[0-9a-f]+\.\.[0-9a-f]+$/)
const added = (path: string, newText: string): GitDiffFile => ({
  path,
  status: "added",
  fingerprint: anyFingerprint,
  oldText: null,
  newText
})
const modified = (path: string, oldText: string, newText: string): GitDiffFile => ({
  path,
  status: "modified",
  fingerprint: anyFingerprint,
  oldText,
  newText
})
const binary = (path: string): GitDiffFile => ({
  path,
  status: "added",
  fingerprint: anyFingerprint,
  oldText: null,
  newText: null,
  omitted: "binary"
})
const deleted: GitDiffFile = {
  path: "gone.txt",
  status: "deleted",
  fingerprint: anyFingerprint,
  oldText: "gone\n",
  newText: null
}
const renamed: GitDiffFile = {
  path: "new-name.txt",
  oldPath: "old-name.txt",
  status: "renamed",
  fingerprint: anyFingerprint,
  oldText: "one\ntwo\nthree\n",
  newText: "one\ntwo\nthree\n"
}

describe("git review", () => {
  it("compares the trees each review mode names without touching the index", async () => {
    const { repo } = makeGitRepo(true)
    write(repo, "gone.txt", "gone\n")
    write(repo, "old-name.txt", "one\ntwo\nthree\n")
    git(repo, "add", ".")
    git(repo, "commit", "-m", "base")
    git(repo, "checkout", "--quiet", "-b", "feature")
    write(repo, "feature.txt", "feature\n")
    git(repo, "add", "feature.txt")
    git(repo, "commit", "-m", "feature")
    // One file staged then edited again, so every mode sees a different side.
    write(repo, "tracked.txt", "staged\n")
    write(repo, "staged-new.txt", "staged new\n")
    git(repo, "add", "tracked.txt", "staged-new.txt")
    write(repo, "tracked.txt", "worktree\n")
    git(repo, "mv", "old-name.txt", "new-name.txt")
    rmSync(join(repo, "gone.txt"))
    write(repo, "untracked.txt", "untracked\n")
    write(repo, "image.bin", Buffer.from([0x89, 0x50, 0x00, 0x01]))
    write(repo, "latin1.txt", Buffer.from("café\n", "latin1"))
    // A submodule commit has no text in this repository, so it never appears.
    git(
      repo,
      "update-index",
      "--add",
      "--cacheinfo",
      `160000,${git(repo, "rev-parse", "HEAD")},sub`
    )
    const index = indexBytes(repo)

    const worktreeFiles = [
      deleted,
      binary("image.bin"),
      binary("latin1.txt"),
      renamed,
      added("staged-new.txt", "staged new\n"),
      modified("tracked.txt", "original\n", "worktree\n"),
      added("untracked.txt", "untracked\n")
    ]
    const cases: ReadonlyArray<{
      readonly mode: GitDiffMode
      readonly base?: string
      readonly files: ReadonlyArray<GitDiffFile>
    }> = [
      { mode: "uncommitted", files: worktreeFiles },
      {
        mode: "staged",
        files: [
          renamed,
          added("staged-new.txt", "staged new\n"),
          modified("tracked.txt", "original\n", "staged\n")
        ]
      },
      {
        mode: "unstaged",
        files: [
          deleted,
          binary("image.bin"),
          binary("latin1.txt"),
          modified("tracked.txt", "staged\n", "worktree\n"),
          added("untracked.txt", "untracked\n")
        ]
      },
      {
        mode: "branch",
        base: "main",
        files: [...worktreeFiles, added("feature.txt", "feature\n")].toSorted((left, right) =>
          left.path < right.path ? -1 : 1
        )
      }
    ]
    for (const { mode, base, files } of cases) {
      expect(await gitDiff(repo, mode), mode).toEqual({
        mode,
        repositoryRoot: git(repo, "rev-parse", "--show-toplevel"),
        ...(base === undefined ? {} : { base }),
        files,
        truncated: false,
        revision: expect.stringMatching(/^[0-9a-f]+\.\.[0-9a-f]+$/)
      })
    }
    expect(indexBytes(repo).equals(index)).toBe(true)
  })

  it("reviews only what changed after the last turn started", async () => {
    const { repo } = makeGitRepo(true)
    await expect(gitDiff(repo, "lastTurn")).rejects.toMatchObject({ code: "no_turn_snapshot" })
    write(repo, "notes.txt", "draft\n")
    write(repo, "tracked.txt", "before turn\n")
    const index = indexBytes(repo)

    expect(await recordTurnStartSnapshot(repo)).toBe(true)
    write(repo, "notes.txt", "draft\nmore\n")
    write(repo, "created.txt", "created\n")
    // A caller that stopped waiting must not get a snapshot of the turn itself.
    const expired = new AbortController()
    expired.abort()
    expect(await recordTurnStartSnapshot(repo, { signal: expired.signal })).toBe(false)

    expect((await gitDiff(repo, "lastTurn")).files).toEqual([
      added("created.txt", "created\n"),
      // Untracked when the turn started, so it was captured and now diffs as an edit.
      modified("notes.txt", "draft\n", "draft\nmore\n")
    ])
    expect(indexBytes(repo).equals(index)).toBe(true)
    expect(await recordTurnStartSnapshot(testTempDir(join(tmpdir(), "codevisor-plain-")))).toBe(
      false
    )
  })

  it("answers a poll with a matching revision without resending files", async () => {
    const { repo } = makeGitRepo(true)
    write(repo, "tracked.txt", "edited\n")
    const first = await gitDiff(repo, "uncommitted")

    const unchanged = await gitDiff(repo, "uncommitted", { knownRevision: first.revision })
    expect(unchanged).toMatchObject({ revision: first.revision, unchanged: true, files: [] })

    write(repo, "tracked.txt", "edited again\n")
    const changed = await gitDiff(repo, "uncommitted", { knownRevision: first.revision })
    expect(changed.unchanged).toBeUndefined()
    expect(changed.revision).not.toBe(first.revision)
    expect(changed.files.map((file) => file.newText)).toEqual(["edited again\n"])
    // A file's fingerprint follows its content: stable while unchanged,
    // new once it changes.
    expect((await gitDiff(repo, "uncommitted")).files[0]!.fingerprint).toBe(
      changed.files[0]!.fingerprint
    )
    expect(changed.files[0]!.fingerprint).not.toBe(first.files[0]!.fingerprint)
  })

  it("treats a repository without commits as all additions", async () => {
    const repo = testTempDir(join(tmpdir(), "codevisor-unborn-"))
    git(repo, "init", "--quiet", "-b", "main")
    write(repo, "first.txt", "first\n")

    expect((await gitDiff(repo, "uncommitted")).files).toEqual([added("first.txt", "first\n")])
    expect((await gitDiff(repo, "staged")).files).toEqual([])
    expect(await recordTurnStartSnapshot(repo)).toBe(true)
    expect((await gitDiff(repo, "lastTurn")).files).toEqual([])
    await expect(gitDiff(repo, "branch")).rejects.toMatchObject({ code: "unknown_base" })
    expect(await gitRefs(repo)).toEqual({ currentBranch: "main", defaultBase: null, branches: [] })
  })

  it("resolves bases from local refs and reports what a folder cannot review", async () => {
    const { repo } = makeGitRepo(true)
    const head = git(repo, "rev-parse", "HEAD")
    git(repo, "branch", "zeta")
    git(repo, "update-ref", "refs/remotes/origin/main", head)
    git(repo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")

    expect(await gitRefs(repo)).toEqual({
      currentBranch: "main",
      defaultBase: "origin/main",
      branches: [
        { name: "main", remote: false },
        { name: "zeta", remote: false },
        { name: "origin/main", remote: true }
      ]
    })
    expect(await gitDiff(repo, "branch")).toMatchObject({ base: "origin/main", files: [] })
    expect(await gitDiff(repo, "branch", { base: "zeta" })).toMatchObject({ base: "zeta" })
    for (const base of ["origin/nope", "--output=/tmp/x"]) {
      await expect(gitDiff(repo, "branch", { base })).rejects.toMatchObject({
        code: "unknown_base",
        message: `Codevisor couldn't find the branch ${base} in this repository.`
      })
    }
    git(repo, "checkout", "--quiet", "--detach")
    expect((await gitRefs(repo)).currentBranch).toBeNull()

    const blob = git(repo, "rev-parse", "HEAD:tracked.txt")
    execFileSync("git", ["update-index", "--index-info"], {
      cwd: repo,
      input: `0 ${"0".repeat(40)}\ttracked.txt\n100644 ${blob} 2\ttracked.txt\n100644 ${blob} 3\ttracked.txt\n`
    })
    await expect(gitDiff(repo, "staged")).rejects.toMatchObject({ code: "unmerged_index" })

    const plain = testTempDir(join(tmpdir(), "codevisor-plain-"))
    await expect(gitDiff(plain, "uncommitted")).rejects.toMatchObject({
      code: "not_git_repository"
    })
    await expect(gitRefs(plain)).rejects.toMatchObject({ code: "not_git_repository" })
  })

  it("budgets repeated blobs per path and admits empty text at the cumulative limit", async () => {
    const { repo } = makeGitRepo(true)
    const paths = [
      "file-00.txt",
      "file-01.txt",
      "file-02.txt",
      "file-03.txt",
      "file-04.txt",
      "file-05.txt",
      "file-06.txt",
      "file-07.txt",
      "file-08.txt",
      "file-09.txt",
      "file-10.txt",
      "file-11.txt",
      "file-12.txt"
    ]
    const content = "x".repeat(1024 * 1024)
    for (const path of paths) write(repo, path, content)
    write(repo, "z-empty.txt", "")
    const blob = git(repo, "hash-object", "file-00.txt")
    const emptyBlob = git(repo, "hash-object", "z-empty.txt")

    const review = await gitDiff(repo, "uncommitted")

    expect(review.truncated).toBe(false)
    expect(review.files).toHaveLength(14)
    expect(review.files.map((file) => file.path)).toEqual([...paths, "z-empty.txt"])
    for (let index = 0; index < 12; index += 1) {
      const { newText, ...identity } = review.files[index]!
      expect(identity).toEqual({
        path: paths[index],
        status: "added",
        fingerprint: `${"0".repeat(blob.length)}..${blob}`,
        oldText: null
      })
      expect(newText).toHaveLength(1024 * 1024)
      expect(Buffer.from(newText!).every((byte) => byte === 0x78)).toBe(true)
    }
    expect(review.files[12]).toEqual({
      path: "file-12.txt",
      status: "added",
      fingerprint: `${"0".repeat(blob.length)}..${blob}`,
      oldText: null,
      newText: null,
      omitted: "tooLarge"
    })
    expect(review.files[13]).toEqual({
      path: "z-empty.txt",
      status: "added",
      fingerprint: `${"0".repeat(emptyBlob.length)}..${emptyBlob}`,
      oldText: null,
      newText: ""
    })
  })

  it("bounds a review by file count and per-file size", async () => {
    const { repo } = makeGitRepo(true)
    write(repo, "a-large.txt", "x".repeat(1024 * 1024 + 1))
    for (let index = 0; index < 300; index += 1) {
      write(repo, `file-${String(index).padStart(3, "0")}.txt`, `${index}\n`)
    }

    const review = await gitDiff(repo, "uncommitted")

    expect(review.truncated).toBe(true)
    expect(review.files).toHaveLength(300)
    expect(review.files[0]).toEqual({
      path: "a-large.txt",
      status: "added",
      fingerprint: anyFingerprint,
      oldText: null,
      newText: null,
      omitted: "tooLarge"
    })
    expect(review.files.at(-1)).toEqual(added("file-298.txt", "298\n"))
  })
})
