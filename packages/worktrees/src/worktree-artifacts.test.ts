import { execFileSync } from "node:child_process"
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  symlinkSync,
  writeFileSync
} from "node:fs"
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
  write(join(path, ".gitignore"), "tmp/\nnode_modules/\n*.local\nsdk/Sources/Generated/\n")
  write(join(path, "src", "app.ts"), "app\n")
  git(path, "add", ".gitignore", "src/app.ts")
  git(path, "commit", "-m", "add sources")
  write(join(path, "tmp", "shot.png"), "pixels")
  write(join(path, "src", "settings.local"), "local\n")
  write(join(path, "node_modules", "junk.js"), "junk\n")
  write(join(path, "sdk", "Sources", "Generated", "ffi.swift"), "ffi\n")
  return path
}

describe("archived worktree artifacts", () => {
  it("keeps gitignored artifacts across archive and restore but drops rebuildable output", async () => {
    const { repo, root } = makeGitRepo(true)
    const path = await makeWorktreeWithArtifacts(repo, root)
    const artifactsDir = join(root, ".archived-artifacts.noindex", "wt-bento")

    const snapshot = await snapshotWorktree(repo, path, "wt-bento")
    expect(await keepArtifacts(path, artifactsDir)).toEqual(["sdk/", "src/settings.local", "tmp/"])
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
    expect(
      readFileSync(join(restorePath, "sdk", "Sources", "Generated", "ffi.swift"), "utf8")
    ).toBe("ffi\n")
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

  it("sets a colliding artifact aside in an ignored folder of the worktree", async () => {
    const { repo, root } = makeGitRepo()
    const artifactsDir = join(root, "kept")
    write(join(artifactsDir, "notes.md"), "artifact\n")
    write(join(artifactsDir, "tmp", "shot.png"), "pixels")
    write(join(repo, "notes.md"), "restored\n")
    git(repo, "add", "notes.md")
    git(repo, "commit", "-m", "notes")
    write(join(repo, ".codevisor-restore-conflicts", "notes.md"), "older conflict\n")

    expect(await returnKeptArtifacts(artifactsDir, repo)).toEqual([
      ".codevisor-restore-conflicts/notes.md-2"
    ])

    expect(readFileSync(join(repo, "notes.md"), "utf8")).toBe("restored\n")
    expect(readFileSync(join(repo, ".codevisor-restore-conflicts", "notes.md-2"), "utf8")).toBe(
      "artifact\n"
    )
    expect(readFileSync(join(repo, "tmp", "shot.png"), "utf8")).toBe("pixels")
    expect(existsSync(artifactsDir)).toBe(false)
    expect(git(repo, "status", "--porcelain", "--", ".codevisor-restore-conflicts")).toBe("")
  })

  it("sets aside an artifact whose destination is a symlink without writing through it", async () => {
    const { root } = makeGitRepo()
    const artifactsDir = join(root, "kept")
    const restorePath = join(root, "restored")
    write(join(artifactsDir, "tmp", "shot.png"), "pixels")
    mkdirSync(join(root, "elsewhere"))
    mkdirSync(restorePath)
    symlinkSync(join(root, "elsewhere"), join(restorePath, "tmp"))

    expect(await returnKeptArtifacts(artifactsDir, restorePath)).toEqual([
      ".codevisor-restore-conflicts/tmp"
    ])
    expect(
      readFileSync(join(restorePath, ".codevisor-restore-conflicts", "tmp", "shot.png"), "utf8")
    ).toBe("pixels")
    expect(existsSync(join(root, "elsewhere", "shot.png"))).toBe(false)
  })

  it.each([
    { name: "the conflicts folder", link: ".codevisor-restore-conflicts" },
    { name: "a folder inside it", link: ".codevisor-restore-conflicts/tmp" }
  ])("refuses to set an artifact aside through a symlinked $name", async ({ link }) => {
    const { root } = makeGitRepo()
    const artifactsDir = join(root, "kept")
    const restorePath = join(root, "restored")
    const outside = join(root, "outside")
    write(join(artifactsDir, "tmp", "shot.png"), "pixels")
    write(join(restorePath, "tmp", "shot.png"), "restored")
    mkdirSync(outside)
    mkdirSync(dirname(join(restorePath, link)), { recursive: true })
    symlinkSync(outside, join(restorePath, link))

    await expect(returnKeptArtifacts(artifactsDir, restorePath)).rejects.toThrow(
      "Refusing to restore artifacts through the symlink"
    )
    expect(readdirSync(outside)).toEqual([])
    expect(readFileSync(join(artifactsDir, "tmp", "shot.png"), "utf8")).toBe("pixels")
  })

  it("fails instead of keeping nothing when it can't list the ignored files", async () => {
    const { root } = makeGitRepo()
    const notARepo = join(root, "plain")
    write(join(notARepo, ".env"), "SECRET=1\n")

    await expect(
      keepArtifacts(notARepo, join(root, "kept"), {
        ...process.env,
        GIT_DIR: join(root, "missing")
      })
    ).rejects.toThrow()
    expect(readFileSync(join(notARepo, ".env"), "utf8")).toBe("SECRET=1\n")
  })

  it("fails a restore it can't read instead of reporting success", async () => {
    const { root } = makeGitRepo()
    write(join(root, "kept"), "not a folder")

    await expect(returnKeptArtifacts(join(root, "kept"), join(root, "restored"))).rejects.toThrow()
    expect(existsSync(join(root, "kept"))).toBe(true)
  })

  it("puts every moved artifact back and fails when one can't be kept", async () => {
    const { repo, root } = makeGitRepo()
    const path = await makeWorktreeWithArtifacts(repo, root)
    const artifactsDir = join(root, "kept")
    write(join(artifactsDir, "tmp"), "blocks the folder\n")

    await expect(keepArtifacts(path, artifactsDir)).rejects.toThrow()

    expect(readFileSync(join(path, "sdk", "Sources", "Generated", "ffi.swift"), "utf8")).toBe(
      "ffi\n"
    )
    expect(readFileSync(join(path, "src", "settings.local"), "utf8")).toBe("local\n")
    expect(readFileSync(join(path, "tmp", "shot.png"), "utf8")).toBe("pixels")
    expect(readdirSync(artifactsDir)).toEqual(["tmp"])
  })

  it("leaves the worktree untouched when it can't create the artifacts folder", async () => {
    const { repo, root } = makeGitRepo()
    const path = await makeWorktreeWithArtifacts(repo, root)
    write(join(root, "blocked"), "not a folder\n")

    await expect(keepArtifacts(path, join(root, "blocked", "kept"))).rejects.toThrow()

    expect(readFileSync(join(path, "src", "settings.local"), "utf8")).toBe("local\n")
    expect(readFileSync(join(root, "blocked"), "utf8")).toBe("not a folder\n")
  })

  it("drops rebuildable folders nested inside a kept folder", async () => {
    const { repo, root } = makeGitRepo()
    const path = await makeWorktreeWithArtifacts(repo, root)
    write(join(path, "tmp", "node_modules", "dep.js"), "dep\n")
    write(join(path, "tmp", "notes", "build", "out.o"), "obj\n")

    await keepArtifacts(path, join(root, "kept"))

    expect(existsSync(join(root, "kept", "tmp", "shot.png"))).toBe(true)
    expect(existsSync(join(root, "kept", "tmp", "node_modules"))).toBe(false)
    expect(existsSync(join(root, "kept", "tmp", "notes", "build"))).toBe(false)
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
