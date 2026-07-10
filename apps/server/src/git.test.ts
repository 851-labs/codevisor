import { execFileSync } from "node:child_process"
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import {
  GitError,
  addWorktree,
  gitBranchDiffTotals,
  isGitWorkTree,
  parseGitNumstat,
  sanitizeGitOutputLine,
  worktreeStartPoint,
  type GitOutputStream
} from "./git.js"

const makeRepo = (): { readonly root: string; readonly repo: string } => {
  const root = mkdtempSync(join(tmpdir(), "herdman-git-"))
  const repo = join(root, "repo")
  mkdirSync(repo)
  execFileSync("git", ["init"], { cwd: repo })
  execFileSync(
    "git",
    ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
    { cwd: repo }
  )
  return { repo, root }
}

describe("git helper", () => {
  it("wraps spawn failures without stderr as GitError", async () => {
    // A nonexistent cwd fails before git can write to stderr, so the error
    // message comes from the spawn error itself.
    const failure = await addWorktree(
      "/nonexistent-herdman-repo",
      "/tmp/nonexistent-herdman-worktree",
      "herdman/none"
    ).catch((cause: unknown) => cause)
    expect(failure).toBeInstanceOf(GitError)
    expect((failure as GitError).message.length).toBeGreaterThan(0)
  })

  it("treats a nonexistent directory as not a git worktree", async () => {
    // The spawn fails before git can write to stderr, exercising the
    // error-message fallback in the buffered git helper.
    expect(await isGitWorkTree("/nonexistent-herdman-repo")).toBe(false)
  })

  it("streams git output lines while adding a worktree", async () => {
    const { repo, root } = makeRepo()
    const lines: Array<readonly [GitOutputStream, string]> = []
    await addWorktree(repo, join(root, "worktree"), "herdman/stream-test", (stream, line) => {
      lines.push([stream, line])
    })
    expect(lines.length).toBeGreaterThan(0)
    // Git narrates worktree creation on stderr ("Preparing worktree ...").
    expect(
      lines.some(([stream, line]) => stream === "stderr" && line.includes("Preparing worktree"))
    ).toBe(true)
  })

  it("resolves no start point for a repo without an origin/main ref", async () => {
    const { repo } = makeRepo()
    expect(await worktreeStartPoint(repo)).toBeUndefined()
  })

  it("parses text numstat totals while ignoring binary markers", () => {
    expect(parseGitNumstat("3\t1\tapp.ts\n-\t-\timage.png\n2\t0\tnew.ts")).toEqual({
      added: 5,
      removed: 1
    })
  })

  it("counts branch edits and untracked text files like the macOS badge", async () => {
    const { repo } = makeRepo()
    writeFileSync(join(repo, "tracked.txt"), "one\ntwo\n")
    execFileSync("git", ["add", "tracked.txt"], { cwd: repo })
    execFileSync(
      "git",
      ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "baseline"],
      { cwd: repo }
    )
    writeFileSync(join(repo, "tracked.txt"), "one\nchanged\nthree\n")
    writeFileSync(join(repo, "untracked.txt"), "alpha\nbeta")
    writeFileSync(join(repo, "binary.dat"), Buffer.from([0, 1, 2]))

    expect(await gitBranchDiffTotals(repo)).toEqual({ added: 4, removed: 1 })
    expect(await gitBranchDiffTotals(join(repo, "missing"))).toBeUndefined()
  })

  it("cuts worktrees from origin/main when the remote-tracking ref exists", async () => {
    // An "origin" repo with one commit on main, cloned locally; the clone's
    // main then drifts ahead with a local-only commit. New worktrees should
    // start from origin/main, not the drifted local main.
    const root = mkdtempSync(join(tmpdir(), "herdman-git-remote-"))
    const origin = join(root, "origin")
    mkdirSync(origin)
    execFileSync("git", ["init", "-b", "main"], { cwd: origin })
    const commit = (cwd: string, message: string) => {
      execFileSync(
        "git",
        ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", message],
        { cwd }
      )
    }
    commit(origin, "remote-tip")
    const clone = join(root, "clone")
    execFileSync("git", ["clone", origin, clone], { cwd: root })
    commit(clone, "local-drift")
    const remoteTip = execFileSync("git", ["rev-parse", "origin/main"], { cwd: clone })
      .toString()
      .trim()

    const startPoint = await worktreeStartPoint(clone)
    expect(startPoint).toBe("origin/main")
    const worktree = join(root, "worktree")
    await addWorktree(clone, worktree, "herdman/from-remote", undefined, startPoint)
    const worktreeHead = execFileSync("git", ["rev-parse", "HEAD"], { cwd: worktree })
      .toString()
      .trim()
    expect(worktreeHead).toBe(remoteTip)
  })

  it("rejects with the collected stderr when git fails", async () => {
    const { repo, root } = makeRepo()
    execFileSync("git", ["branch", "herdman/taken"], { cwd: repo })
    const failure = await addWorktree(repo, join(root, "worktree"), "herdman/taken").catch(
      (cause: unknown) => cause
    )
    expect(failure).toBeInstanceOf(GitError)
    expect((failure as GitError).message).toContain("taken")
  })

  it("strips ANSI escapes and control characters from log lines", () => {
    expect(sanitizeGitOutputLine("\u001B[38;2;5;5;5m+\u001B[38;2;11;11;11m-\u001B[m")).toBe("+-")
    expect(sanitizeGitOutputLine("\u001B]8;;https://example.com\u0007link\u001B]8;;\u0007")).toBe(
      "link"
    )
    expect(sanitizeGitOutputLine("\u001B[2K\u001B[1G")).toBe("")
    expect(sanitizeGitOutputLine("plain text   ")).toBe("plain text")
    // Tabs survive (legitimate log indentation); other control chars go.
    expect(sanitizeGitOutputLine("bell\u0007 and tab\u0009end")).toBe("bell and tab\u0009end")
  })

  it("emits distinct sanitized frames for progress-style repainting output", async () => {
    // A fake `git` behaving like a TUI hook: colored panels, carriage-return
    // repaints of the same frame, and erase sequences on otherwise-empty lines.
    const fakeBin = mkdtempSync(join(tmpdir(), "herdman-fake-git-"))
    const fakeGit = join(fakeBin, "git")
    writeFileSync(
      fakeGit,
      [
        "#!/bin/sh",
        "printf '\\033[38;2;5;5;5mrefs pull: 1/12\\033[m\\r'",
        "printf '\\033[38;2;5;5;5mrefs pull: 1/12\\033[m\\r'",
        "printf 'refs pull: 12/12\\n'",
        "printf '\\033[2K\\033[1G\\n'",
        "printf 'done\\n'",
        "exit 0",
        ""
      ].join("\n")
    )
    chmodSync(fakeGit, 0o755)
    const previousPath = process.env["PATH"]
    process.env["PATH"] = `${fakeBin}:${previousPath ?? ""}`
    try {
      const lines: Array<string> = []
      await addWorktree(fakeBin, join(fakeBin, "worktree"), "herdman/fake", (_stream, line) => {
        lines.push(line)
      })
      expect(lines).toEqual(["refs pull: 1/12", "refs pull: 12/12", "done"])
    } finally {
      process.env["PATH"] = previousPath
    }
  })

  it("falls back to the exit code for silent failures and flushes partial output lines", async () => {
    // A fake `git` that emits an unterminated stdout line and exits non-zero
    // without writing to stderr.
    const fakeBin = mkdtempSync(join(tmpdir(), "herdman-fake-git-"))
    const fakeGit = join(fakeBin, "git")
    writeFileSync(fakeGit, "#!/bin/sh\nprintf 'partial-stdout-line'\nexit 2\n")
    chmodSync(fakeGit, 0o755)
    const previousPath = process.env["PATH"]
    process.env["PATH"] = `${fakeBin}:${previousPath ?? ""}`
    try {
      const lines: Array<readonly [GitOutputStream, string]> = []
      const failure = await addWorktree(
        fakeBin,
        join(fakeBin, "worktree"),
        "herdman/fake",
        (stream, line) => {
          lines.push([stream, line])
        }
      ).catch((cause: unknown) => cause)
      expect(failure).toBeInstanceOf(GitError)
      expect((failure as GitError).message).toContain("exited with code 2")
      expect(lines).toContainEqual(["stdout", "partial-stdout-line"])
    } finally {
      process.env["PATH"] = previousPath
    }
  })
})
