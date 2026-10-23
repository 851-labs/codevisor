import { execFileSync } from "node:child_process"
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"

import { describe, expect, it } from "vitest"

import { makeGitRepo } from "./git-test-support.js"
import { addWorktree } from "./git.js"
import {
  removeArchivedWorktreeFiles,
  restoreWorktree,
  snapshotWorktree
} from "./worktree-archive.js"
import { keepArtifacts, meaningfulIgnoredPaths, returnKeptArtifacts } from "./worktree-artifacts.js"

const git = (repo: string, ...args: ReadonlyArray<string>): string =>
  execFileSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], {
    cwd: repo,
    encoding: "utf8"
  }).trim()

const write = (path: string, contents: string): void => {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, contents)
}

const makeWorktreeWithArtifacts = async (repo: string, root: string): Promise<string> => {
  const path = join(root, "bento")
  await addWorktree(repo, path, "codevisor/bento")
  write(join(path, ".gitignore"), "tmp/\nnode_modules/\n*.local\n")
  write(join(path, "src", "app.ts"), "app\n")
  git(path, "add", ".gitignore", "src/app.ts")
  git(path, "commit", "-m", "add sources")
  write(join(path, "tmp", "shot.png"), "pixels")
  write(join(path, "src", "settings.local"), "local\n")
  write(join(path, "node_modules", "junk.js"), "junk\n")
  return path
}

describe("archived worktree artifacts", () => {
  it("keeps gitignored artifacts across archive and restore but drops rebuildable output", async () => {
    const { repo, root } = makeGitRepo(true)
    const path = await makeWorktreeWithArtifacts(repo, root)
    const artifactsDir = join(root, ".archived-artifacts.noindex", "wt-bento")

    const snapshot = await snapshotWorktree(repo, path, "wt-bento")
    expect(await keepArtifacts(path, artifactsDir)).toEqual(["src/settings.local", "tmp/"])
    const trashed = await removeArchivedWorktreeFiles(repo, path, "codevisor/bento", {
      trashRoot: join(root, ".trash"),
      worktreeId: "wt-bento"
    })
    await trashed.purged

    expect(readFileSync(join(artifactsDir, "tmp", "shot.png"), "utf8")).toBe("pixels")
    expect(existsSync(join(artifactsDir, "node_modules"))).toBe(false)

    const restored = await restoreWorktree({
      repoDir: repo,
      worktreePathFor: (name) => join(root, name),
      originalName: "bento",
      parentSha: snapshot.parentSha,
      snapshotRef: snapshot.snapshotRef,
      takenNames: new Set()
    })
    const restorePath = join(root, restored.name)
    await returnKeptArtifacts(artifactsDir, restorePath)

    expect(readFileSync(join(restorePath, "tmp", "shot.png"), "utf8")).toBe("pixels")
    expect(readFileSync(join(restorePath, "src", "settings.local"), "utf8")).toBe("local\n")
    expect(readFileSync(join(restorePath, "src", "app.ts"), "utf8")).toBe("app\n")
    expect(existsSync(join(restorePath, "node_modules"))).toBe(false)
    expect(existsSync(artifactsDir)).toBe(false)
  })

  it("keeps nothing from a vanished worktree and restores nothing when nothing was kept", async () => {
    const { repo, root } = makeGitRepo()

    expect(await keepArtifacts(join(root, "vanished"), join(root, "kept"))).toEqual([])
    expect(existsSync(join(root, "kept"))).toBe(false)

    await returnKeptArtifacts(join(root, "kept"), repo)
    expect(git(repo, "status", "--porcelain")).toBe("")
  })

  it("keeps the restored file when a kept artifact collides with it", async () => {
    const { root } = makeGitRepo()
    const artifactsDir = join(root, "kept")
    const restorePath = join(root, "restored")
    write(join(artifactsDir, "notes.md"), "artifact\n")
    write(join(artifactsDir, "tmp", "shot.png"), "pixels")
    write(join(restorePath, "notes.md"), "restored\n")

    await returnKeptArtifacts(artifactsDir, restorePath)

    expect(readFileSync(join(restorePath, "notes.md"), "utf8")).toBe("restored\n")
    expect(readFileSync(join(restorePath, "tmp", "shot.png"), "utf8")).toBe("pixels")
    expect(existsSync(artifactsDir)).toBe(false)
  })
})

describe("meaningfulIgnoredPaths", () => {
  it("keeps agent artifacts and drops rebuildable output", () => {
    expect(
      meaningfulIgnoredPaths([
        ".env",
        "tmp/",
        "node_modules/",
        "apps/www/dist/",
        "src/generated.local.json",
        "target/debug/",
        "packages/swift/.build/",
        "coverage/"
      ])
    ).toEqual([".env", "tmp/", "src/generated.local.json"])
  })
})
