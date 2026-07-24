import { execFileSync } from "node:child_process"
import { chmodSync, existsSync, mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import {
  CloneError,
  GitError,
  addWorktree,
  classifyCloneFailure,
  cloneRepository,
  gitBranchDiffTotals,
  isGitWorkTree,
  isWorktreeBranchCollision,
  listCodevisorWorktreeBranchNames,
  parseGitNumstat,
  rollbackFailedWorktree,
  sanitizeGitOutputLine,
  worktreeStartPoint,
  type GitOutputStream
} from "./git.js"

const makeRepo = (): { readonly root: string; readonly repo: string } => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-git-"))
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
      "/nonexistent-codevisor-repo",
      "/tmp/nonexistent-codevisor-worktree",
      "codevisor/none"
    ).catch((cause: unknown) => cause)
    expect(failure).toBeInstanceOf(GitError)
    expect((failure as GitError).message.length).toBeGreaterThan(0)
  })

  it("treats a nonexistent directory as not a git worktree", async () => {
    // The spawn fails before git can write to stderr, exercising the
    // error-message fallback in the buffered git helper.
    expect(await isGitWorkTree("/nonexistent-codevisor-repo")).toBe(false)
  })

  it("lists names already occupying the shared Codevisor branch namespace", async () => {
    const { repo } = makeRepo()
    execFileSync("git", ["branch", "codevisor/chicken-fingers-8394"], { cwd: repo })
    execFileSync("git", ["branch", "unrelated"], { cwd: repo })

    expect(await listCodevisorWorktreeBranchNames(repo)).toEqual(["chicken-fingers-8394"])
  })

  it("streams git output lines while adding a worktree", async () => {
    const { repo, root } = makeRepo()
    const lines: Array<readonly [GitOutputStream, string]> = []
    await addWorktree(repo, join(root, "worktree"), "codevisor/stream-test", (stream, line) => {
      lines.push([stream, line])
    })
    expect(lines.length).toBeGreaterThan(0)
    // Git narrates worktree creation on stderr ("Preparing worktree ...").
    expect(
      lines.some(([stream, line]) => stream === "stderr" && line.includes("Preparing worktree"))
    ).toBe(true)
  })

  it("uses the caller environment for checkout hooks", async () => {
    const { repo, root } = makeRepo()
    const helperBin = join(root, "resolved-bin")
    const helper = join(helperBin, "git-lfs")
    const marker = join(root, "hook-ran")
    mkdirSync(helperBin)
    writeFileSync(helper, '#!/bin/sh\nprintf "found" > "$CODEVISOR_TEST_MARKER"\n')
    chmodSync(helper, 0o755)
    writeFileSync(
      join(repo, ".git", "hooks", "post-checkout"),
      "#!/bin/sh\ncommand -v git-lfs >/dev/null 2>&1 || exit 2\ngit-lfs\n"
    )
    chmodSync(join(repo, ".git", "hooks", "post-checkout"), 0o755)

    await addWorktree(
      repo,
      join(root, "worktree"),
      "codevisor/resolved-hook-path",
      undefined,
      undefined,
      {
        ...process.env,
        CODEVISOR_TEST_MARKER: marker,
        PATH: `${helperBin}:/usr/bin:/bin`
      }
    )

    expect(existsSync(marker)).toBe(true)
  })

  it("rolls back a worktree and branch left registered by a failed checkout hook", async () => {
    const { repo, root } = makeRepo()
    const worktree = join(root, "failed-worktree")
    const branch = "codevisor/failed-hook"
    const hook = join(repo, ".git", "hooks", "post-checkout")
    writeFileSync(hook, "#!/bin/sh\necho checkout hook failed >&2\nexit 2\n")
    chmodSync(hook, 0o755)

    const failure = await addWorktree(repo, worktree, branch).catch((cause: unknown) => cause)
    expect(failure).toBeInstanceOf(GitError)
    expect(existsSync(worktree)).toBe(true)

    expect(await rollbackFailedWorktree(repo, worktree, branch)).toBe(true)
    expect(existsSync(worktree)).toBe(false)
    expect(() =>
      execFileSync("git", ["show-ref", "--verify", `refs/heads/${branch}`], {
        cwd: repo,
        stdio: "ignore"
      })
    ).toThrow()
  })

  it("does nothing when a failed worktree was never registered", async () => {
    const { repo, root } = makeRepo()
    expect(
      await rollbackFailedWorktree(repo, join(root, "missing-worktree"), "codevisor/never-created")
    ).toBe(false)
  })

  it("resolves no start point for a repo without an origin/main ref", async () => {
    const { repo } = makeRepo()
    expect(await worktreeStartPoint(repo)).toBeUndefined()
  })

  it("parses text numstat totals while ignoring binary markers", () => {
    expect(parseGitNumstat("malformed\n3\t1\tapp.ts\n-\t-\timage.png\n2\t0\tnew.ts")).toEqual({
      added: 5,
      removed: 1
    })
  })

  it("counts branch edits and untracked text files like the macOS badge", async () => {
    const { repo } = makeRepo()
    writeFileSync(join(repo, "tracked.txt"), "one\ntwo\n")
    execFileSync("git", ["add", "tracked.txt"], { cwd: repo })
    execFileSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "baseline"], {
      cwd: repo
    })
    writeFileSync(join(repo, "tracked.txt"), "one\nchanged\nthree\n")
    writeFileSync(join(repo, "untracked.txt"), "alpha\nbeta")
    writeFileSync(join(repo, "trailing-newline.txt"), "alpha\n")
    writeFileSync(join(repo, "empty.txt"), "")
    writeFileSync(join(repo, "too-large.txt"), Buffer.alloc(4_000_001, 65))
    writeFileSync(join(repo, "binary.dat"), Buffer.from([0, 1, 2]))
    symlinkSync(join(repo, "missing-target"), join(repo, "dangling-link"))

    expect(await gitBranchDiffTotals(repo)).toEqual({ added: 5, removed: 1 })
    expect(await gitBranchDiffTotals(join(repo, "missing"))).toBeUndefined()
  })

  it("hides failures while reading the untracked-file list", async () => {
    for (const [name, diagnostic] of [
      ["stderr", "echo raw failure >&2"],
      ["silent", ""]
    ] as const) {
      const fakeBin = mkdtempSync(join(tmpdir(), `codevisor-fake-git-${name}-`))
      const fakeGit = join(fakeBin, "git")
      writeFileSync(
        fakeGit,
        [
          "#!/bin/sh",
          'case "$1" in',
          "  rev-parse) echo true; exit 0 ;;",
          "  merge-base) echo fake-base; exit 0 ;;",
          "  diff) printf '1\\t0\\tfile.txt\\n'; exit 0 ;;",
          `  ls-files) ${diagnostic || ":"}; exit 2 ;;`,
          "esac",
          "exit 2",
          ""
        ].join("\n")
      )
      chmodSync(fakeGit, 0o755)
      const previousPath = process.env["PATH"]
      process.env["PATH"] = `${fakeBin}:${previousPath ?? ""}`
      try {
        expect(await gitBranchDiffTotals(fakeBin)).toBeUndefined()
      } finally {
        process.env["PATH"] = previousPath
      }
    }
  })

  it("falls back to HEAD when conventional base refs have no merge base", async () => {
    const fakeBin = mkdtempSync(join(tmpdir(), "codevisor-fake-git-no-base-"))
    const fakeGit = join(fakeBin, "git")
    writeFileSync(
      fakeGit,
      [
        "#!/bin/sh",
        'case "$1" in',
        "  rev-parse) echo true; exit 0 ;;",
        "  merge-base) exit 0 ;;",
        "  diff) printf '2\\t1\\tfile.txt\\n'; exit 0 ;;",
        "  ls-files) exit 0 ;;",
        "esac",
        "exit 2",
        ""
      ].join("\n")
    )
    chmodSync(fakeGit, 0o755)
    const previousPath = process.env["PATH"]
    process.env["PATH"] = `${fakeBin}:${previousPath ?? ""}`
    try {
      expect(await gitBranchDiffTotals(fakeBin)).toEqual({ added: 2, removed: 1 })
    } finally {
      process.env["PATH"] = previousPath
    }
  })

  it("refreshes origin/main before cutting a worktree from it", async () => {
    // Clone an origin, then advance both the remote and local branches without
    // fetching. The worktree should start from the new remote tip, not stale
    // origin/main or the drifted local main.
    const root = mkdtempSync(join(tmpdir(), "codevisor-git-remote-"))
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
    commit(origin, "new-remote-tip")
    const staleRemoteTip = execFileSync("git", ["rev-parse", "origin/main"], { cwd: clone })
      .toString()
      .trim()
    const remoteTip = execFileSync("git", ["rev-parse", "main"], { cwd: origin }).toString().trim()
    expect(staleRemoteTip).not.toBe(remoteTip)

    const startPoint = await worktreeStartPoint(clone)
    expect(startPoint).toBe("origin/main")
    const worktree = join(root, "worktree")
    await addWorktree(clone, worktree, "codevisor/from-remote", undefined, startPoint)
    const worktreeHead = execFileSync("git", ["rev-parse", "HEAD"], { cwd: worktree })
      .toString()
      .trim()
    expect(worktreeHead).toBe(remoteTip)
  })

  it("uses cached origin/main when refreshing it fails", async () => {
    const root = mkdtempSync(join(tmpdir(), "codevisor-git-offline-"))
    const origin = join(root, "origin")
    mkdirSync(origin)
    execFileSync("git", ["init", "-b", "main"], { cwd: origin })
    execFileSync(
      "git",
      ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
      { cwd: origin }
    )
    const clone = join(root, "clone")
    execFileSync("git", ["clone", origin, clone], { cwd: root })
    execFileSync("git", ["remote", "set-url", "origin", join(root, "missing-origin")], {
      cwd: clone
    })

    expect(await worktreeStartPoint(clone)).toBe("origin/main")
  })

  it("rejects with the collected stderr when git fails", async () => {
    const { repo, root } = makeRepo()
    execFileSync("git", ["branch", "codevisor/taken"], { cwd: repo })
    const failure = await addWorktree(repo, join(root, "worktree"), "codevisor/taken").catch(
      (cause: unknown) => cause
    )
    expect(failure).toBeInstanceOf(GitError)
    expect((failure as GitError).message).toContain("taken")
    expect(isWorktreeBranchCollision(failure)).toBe(true)
    expect(isWorktreeBranchCollision(new GitError("add-worktree", "fatal: another failure"))).toBe(
      false
    )
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
    const fakeBin = mkdtempSync(join(tmpdir(), "codevisor-fake-git-"))
    const fakeGit = join(fakeBin, "git")
    writeFileSync(
      fakeGit,
      [
        "#!/bin/sh",
        "printf '\\033[38;2;5;5;5mgit submodule update: 1/12\\033[m\\r'",
        "printf '\\033[38;2;5;5;5mgit submodule update: 1/12\\033[m\\r'",
        "printf 'git submodule update: 12/12\\n'",
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
      await addWorktree(fakeBin, join(fakeBin, "worktree"), "codevisor/fake", (_stream, line) => {
        lines.push(line)
      })
      expect(lines).toEqual(["git submodule update: 1/12", "git submodule update: 12/12", "done"])
    } finally {
      process.env["PATH"] = previousPath
    }
  })

  it("falls back to the exit code for silent failures and flushes partial output lines", async () => {
    // A fake `git` that emits an unterminated stdout line and exits non-zero
    // without writing to stderr.
    const fakeBin = mkdtempSync(join(tmpdir(), "codevisor-fake-git-"))
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
        "codevisor/fake",
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

describe("classifyCloneFailure", () => {
  it("maps git stderr onto actionable failure codes", () => {
    const cases: ReadonlyArray<readonly [string, string | undefined]> = [
      ["fatal: Authentication failed for 'https://x'", "auth_failed"],
      ["fatal: could not read Username for 'https://github.com'", "auth_failed"],
      ["fatal: could not read Password for 'https://github.com'", "auth_failed"],
      ["git@github.com: Permission denied (publickey).", "auth_failed"],
      ["Host key verification failed.", "auth_failed"],
      ["remote: Support for password authentication was removed.", "auth_failed"],
      ["remote: Repository not found.", "repo_not_found"],
      ["fatal: unable to access 'https://x/': Could not resolve host: x", "network"],
      ["ssh: connect to host x port 22: Connection timed out", "network"],
      ["ssh: connect to host x port 22: Connection refused", "network"],
      ["fatal: write error: No space left on device", "disk_full"],
      ["fatal: 'x' does not appear to be a git repository", "invalid_url"],
      ["remote: is not a valid repository name", "invalid_url"],
      ["fatal: something novel exploded", undefined]
    ]
    for (const [stderr, expected] of cases) {
      expect(classifyCloneFailure(stderr), stderr).toBe(expected)
    }
  })
})

describe("cloneRepository", () => {
  it("clones a local origin and streams distinct progress lines", async () => {
    const { repo } = makeRepo()
    const destination = join(mkdtempSync(join(tmpdir(), "codevisor-clone-")), "checkout")
    const lines: Array<string> = []
    await cloneRepository(`file://${repo}`, destination, (_stream, line) => {
      lines.push(line)
    })
    expect(await isGitWorkTree(destination)).toBe(true)
    expect(lines.length).toBeGreaterThan(0)
  })

  it("fails with a classified CloneError and never hangs on prompts", async () => {
    const destination = join(mkdtempSync(join(tmpdir(), "codevisor-clone-fail-")), "checkout")
    const failure = await cloneRepository("file:///nonexistent-origin.git", destination).then(
      () => undefined,
      (cause: unknown) => cause
    )
    expect(failure).toBeInstanceOf(CloneError)
    expect((failure as CloneError).code).toBe("invalid_url")
  })

  it("streams stdout lines and honors a caller-provided GIT_SSH_COMMAND", async () => {
    const fakeBin = mkdtempSync(join(tmpdir(), "codevisor-fake-git-stdout-"))
    writeFileSync(
      join(fakeBin, "git"),
      '#!/bin/sh\necho "stdout line"\necho "ssh=$GIT_SSH_COMMAND"\nexit 0\n'
    )
    chmodSync(join(fakeBin, "git"), 0o755)
    const previousPath = process.env["PATH"]
    const previousSsh = process.env["GIT_SSH_COMMAND"]
    process.env["PATH"] = fakeBin
    process.env["GIT_SSH_COMMAND"] = "ssh -i /custom/key -oBatchMode=yes"
    try {
      const lines: Array<readonly [GitOutputStream, string]> = []
      await cloneRepository("https://example.com/x.git", "/tmp/unused", (stream, line) => {
        lines.push([stream, line])
      })
      expect(lines).toContainEqual(["stdout", "stdout line"])
      expect(lines).toContainEqual(["stdout", "ssh=ssh -i /custom/key -oBatchMode=yes"])
    } finally {
      process.env["PATH"] = previousPath
      if (previousSsh === undefined) {
        delete process.env["GIT_SSH_COMMAND"]
      } else {
        process.env["GIT_SSH_COMMAND"] = previousSsh
      }
    }
  })

  it("reports the exit code when git dies silently and spawn errors when git is missing", async () => {
    // Fake git that exits without writing anything.
    const fakeBin = mkdtempSync(join(tmpdir(), "codevisor-fake-git-clone-"))
    writeFileSync(join(fakeBin, "git"), "#!/bin/sh\nexit 3\n")
    chmodSync(join(fakeBin, "git"), 0o755)
    const previousPath = process.env["PATH"]
    process.env["PATH"] = fakeBin
    try {
      const silent = await cloneRepository("https://example.com/x.git", "/tmp/unused").then(
        () => undefined,
        (cause: unknown) => cause
      )
      expect(silent).toBeInstanceOf(CloneError)
      expect((silent as CloneError).message).toContain("exited with code 3")

      // Empty PATH: the spawn itself fails.
      process.env["PATH"] = mkdtempSync(join(tmpdir(), "codevisor-empty-path-"))
      const spawnFailure = await cloneRepository("https://example.com/x.git", "/tmp/unused").then(
        () => undefined,
        (cause: unknown) => cause
      )
      expect(spawnFailure).toBeInstanceOf(CloneError)
      expect((spawnFailure as CloneError).code).toBeUndefined()
    } finally {
      process.env["PATH"] = previousPath
    }
  })
})
