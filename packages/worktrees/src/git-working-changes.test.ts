import { execFileSync } from "node:child_process"
import { chmodSync, mkdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { makeGitRepo, testTempDir } from "./git-test-support.js"
import {
  gitWorkingChanges,
  maxGitWorkingChanges,
  parseNameStatus,
  parseNumstat
} from "./git-working-changes.js"

const git = (cwd: string, ...args: string[]) =>
  execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.test", ...args], {
    cwd,
    stdio: "ignore"
  })

const byPath = (files: ReadonlyArray<{ readonly path: string }>) =>
  [...files].toSorted((left, right) => left.path.localeCompare(right.path))

describe("git working changes", () => {
  it("lists uncommitted, staged and untracked files with line counts", async () => {
    const { repo } = makeGitRepo()
    mkdirSync(join(repo, "src"))
    writeFileSync(join(repo, "src", "app.ts"), "one\ntwo\nthree\n")
    writeFileSync(join(repo, "gone.txt"), "a\nb\n")
    writeFileSync(join(repo, "image.png"), Buffer.from([0, 1, 2, 3]))
    writeFileSync(join(repo, ".gitignore"), "ignored.log\n")
    git(repo, "add", ".")
    git(repo, "commit", "-m", "baseline")

    writeFileSync(join(repo, "src", "app.ts"), "one\nchanged\nthree\nfour\n")
    rmSync(join(repo, "gone.txt"))
    writeFileSync(join(repo, "image.png"), Buffer.from([0, 9, 9, 9]))
    writeFileSync(join(repo, "staged.ts"), "export {}\n")
    git(repo, "add", "staged.ts")
    mkdirSync(join(repo, "notes"))
    writeFileSync(join(repo, "notes", "todo.md"), "- a\n- b\n- c")
    writeFileSync(join(repo, "ignored.log"), "noise\n")

    const changes = await gitWorkingChanges(repo)
    expect(changes.truncated).toBe(false)
    expect(byPath(changes.files)).toEqual([
      { path: "gone.txt", status: "deleted", added: 0, removed: 2 },
      { path: "image.png", status: "modified", added: 0, removed: 0 },
      { path: "notes/todo.md", status: "added", added: 3, removed: 0 },
      { path: "src/app.ts", status: "modified", added: 2, removed: 1 },
      { path: "staged.ts", status: "added", added: 1, removed: 0 }
    ])
    writeFileSync(join(repo, "src", "extra.ts"), "x\n")
    expect(byPath((await gitWorkingChanges(join(repo, "src"))).files)).toEqual([
      { path: "app.ts", status: "modified", added: 2, removed: 1 },
      { path: "extra.ts", status: "added", added: 1, removed: 0 }
    ])
  })

  it("returns nothing for a repository without commits", async () => {
    const root = testTempDir(join(tmpdir(), "codevisor-git-empty-"))
    execFileSync("git", ["init", "-b", "main", root], { stdio: "ignore" })
    writeFileSync(join(root, "draft.txt"), "draft\n")
    expect(await gitWorkingChanges(root)).toEqual({ files: [], truncated: false })
  })

  it("caps the list and reports that it was truncated", async () => {
    const { repo } = makeGitRepo()
    for (let index = 0; index <= maxGitWorkingChanges; index += 1) {
      writeFileSync(join(repo, `file-${index}.txt`), `${index}\n`)
    }
    const changes = await gitWorkingChanges(repo)
    expect(changes.files).toHaveLength(maxGitWorkingChanges)
    expect(changes.truncated).toBe(true)
  })

  it("keeps tracked changes ahead of untracked files when both overflow", async () => {
    const fakeBin = testTempDir(join(tmpdir(), "codevisor-fake-git-working-"))
    const names = Array.from({ length: maxGitWorkingChanges + 1 }, (_, index) => `M\\0t${index}\\0`)
    writeFileSync(
      join(fakeBin, "git"),
      [
        "#!/bin/sh",
        'case "$*" in',
        "  rev-parse*) exit 0 ;;",
        "  *--numstat*) printf '4\\t1\\tt0\\0'; exit 0 ;;",
        `  *--name-status*) printf '${names.join("")}'; exit 0 ;;`,
        "  ls-files*) printf 'loose.txt\\0'; exit 0 ;;",
        "esac",
        "exit 2",
        ""
      ].join("\n")
    )
    chmodSync(join(fakeBin, "git"), 0o755)
    const previousPath = process.env["PATH"]
    process.env["PATH"] = `${fakeBin}:${previousPath ?? ""}`
    try {
      const changes = await gitWorkingChanges(fakeBin)
      expect(changes.truncated).toBe(true)
      expect(changes.files).toHaveLength(maxGitWorkingChanges)
      expect(changes.files[0]).toEqual({ path: "t0", status: "modified", added: 4, removed: 1 })
      expect(changes.files[1]).toEqual({ path: "t1", status: "modified", added: 0, removed: 0 })
      expect(changes.files.some((file) => file.path === "loose.txt")).toBe(false)
    } finally {
      process.env["PATH"] = previousPath
    }
  })

  it("parses NUL-separated name-status and numstat output", () => {
    expect([...parseNameStatus("A\0new.ts\0T\0link\0D\0old.ts\0M")]).toEqual([
      ["new.ts", "added"],
      ["link", "modified"],
      ["old.ts", "deleted"]
    ])
    expect([...parseNumstat("3\t1\tapp.ts\0-\t-\timage.png\0broken\0\t\t\0")]).toEqual([
      ["app.ts", { added: 3, removed: 1 }],
      ["image.png", { added: 0, removed: 0 }]
    ])
  })
})
