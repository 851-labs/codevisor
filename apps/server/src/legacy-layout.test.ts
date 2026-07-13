import { execFile } from "node:child_process"
import {
  lstat,
  mkdtemp,
  mkdir,
  readFile,
  readlink,
  realpath,
  rename,
  rm,
  symlink,
  writeFile
} from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"
import { describe, expect, it } from "vitest"
import { migrateLegacyLayout } from "./legacy-layout.js"

const execFileAsync = promisify(execFile)

describe("Codevisor legacy file layout migration", () => {
  it("moves application data, renames the database, and preserves worktrees", async () => {
    const home = await mkdtemp(join(tmpdir(), "codevisor-layout-"))
    const legacyData = join(home, "Library", "Application Support", "HerdMan")
    const data = join(home, "Library", "Application Support", "Codevisor")
    const legacyWorktrees = join(home, "herdman")
    const worktrees = join(home, "codevisor")
    await mkdir(legacyData, { recursive: true })
    await mkdir(join(legacyWorktrees, "project", "worktree"), { recursive: true })
    await writeFile(join(legacyData, "herdman-server.sqlite"), "database")
    await writeFile(join(legacyData, "settings.json"), "settings")
    await writeFile(join(legacyWorktrees, "project", "worktree", "progress.txt"), "unsaved")

    const progress: Array<{ state: string; completed: number; total: number }> = []
    await migrateLegacyLayout({
      databasePath: join(data, "codevisor-server.sqlite"),
      worktreesRoot: worktrees,
      homeDirectory: home,
      onProgress: ({ state, completed, total }) => progress.push({ state, completed, total })
    })

    await expect(readFile(join(data, "codevisor-server.sqlite"), "utf8")).resolves.toBe("database")
    await expect(readFile(join(data, "settings.json"), "utf8")).resolves.toBe("settings")
    await expect(
      readFile(join(worktrees, "project", "worktree", "progress.txt"), "utf8")
    ).resolves.toBe("unsaved")
    expect(progress.at(0)?.state).toBe("running")
    expect(progress.at(-1)).toMatchObject({ state: "completed", completed: 3, total: 3 })
  })

  it("merges directories without overwriting a conflicting destination file", async () => {
    const home = await mkdtemp(join(tmpdir(), "codevisor-layout-conflict-"))
    const legacyData = join(home, "Library", "Application Support", "HerdMan")
    const data = join(home, "Library", "Application Support", "Codevisor")
    await mkdir(legacyData, { recursive: true })
    await mkdir(data, { recursive: true })
    await writeFile(join(legacyData, "settings.json"), "old")
    await writeFile(join(data, "settings.json"), "new")

    const states: string[] = []
    await expect(
      migrateLegacyLayout({
        databasePath: join(data, "codevisor-server.sqlite"),
        worktreesRoot: join(home, "codevisor"),
        homeDirectory: home,
        onProgress: ({ state }) => states.push(state)
      })
    ).rejects.toThrow("different contents")
    await expect(readFile(join(data, "settings.json"), "utf8")).resolves.toBe("new")
    await expect(readFile(join(legacyData, "settings.json"), "utf8")).resolves.toBe("old")
    expect(states.at(-1)).toBe("failed")
  })

  it("deduplicates matching files and symlinks while merging", async () => {
    const home = await mkdtemp(join(tmpdir(), "codevisor-layout-dedupe-"))
    const legacyData = join(home, "Library", "Application Support", "HerdMan")
    const data = join(home, "Library", "Application Support", "Codevisor")
    await mkdir(legacyData, { recursive: true })
    await mkdir(data, { recursive: true })
    await writeFile(join(legacyData, "settings.json"), "same")
    await writeFile(join(data, "settings.json"), "same")
    await writeFile(join(legacyData, "herdman-server.sqlite"), "same database")
    await writeFile(join(data, "codevisor-server.sqlite"), "same database")
    await symlink("shared-target", join(legacyData, "shared-link"))
    await symlink("shared-target", join(data, "shared-link"))

    await migrateLegacyLayout({
      databasePath: join(data, "codevisor-server.sqlite"),
      worktreesRoot: join(home, "codevisor"),
      homeDirectory: home
    })

    await expect(readFile(join(data, "settings.json"), "utf8")).resolves.toBe("same")
    await expect(readFile(join(data, "codevisor-server.sqlite"), "utf8")).resolves.toBe(
      "same database"
    )
    await expect(readlink(join(data, "shared-link"))).resolves.toBe("shared-target")
    await expect(lstat(legacyData)).rejects.toMatchObject({ code: "ENOENT" })
  })

  it("blocks conflicting symlinks and differently sized files", async () => {
    const home = await mkdtemp(join(tmpdir(), "codevisor-layout-link-conflict-"))
    const legacyData = join(home, "Library", "Application Support", "HerdMan")
    const data = join(home, "Library", "Application Support", "Codevisor")
    await mkdir(legacyData, { recursive: true })
    await mkdir(data, { recursive: true })
    await symlink("legacy-target", join(legacyData, "a-link"))
    await symlink("codevisor-target", join(data, "a-link"))

    await expect(
      migrateLegacyLayout({
        databasePath: join(data, "codevisor-server.sqlite"),
        worktreesRoot: join(home, "codevisor"),
        homeDirectory: home
      })
    ).rejects.toThrow("different contents")

    await expect(readlink(join(legacyData, "a-link"))).resolves.toBe("legacy-target")
    await expect(readlink(join(data, "a-link"))).resolves.toBe("codevisor-target")

    await rm(join(legacyData, "a-link"))
    await rm(join(data, "a-link"))
    await writeFile(join(legacyData, "a-link"), "legacy contents")
    await writeFile(join(data, "a-link"), "new")
    await expect(
      migrateLegacyLayout({
        databasePath: join(data, "codevisor-server.sqlite"),
        worktreesRoot: join(home, "codevisor"),
        homeDirectory: home
      })
    ).rejects.toThrow("different contents")
  })

  it("moves dot-directory databases and archives legacy updater logs", async () => {
    const home = await mkdtemp(join(tmpdir(), "codevisor-layout-dotdir-"))
    const legacyData = join(home, ".herdman")
    const data = join(home, ".codevisor")
    await mkdir(legacyData, { recursive: true })
    await writeFile(join(legacyData, "server.log"), "legacy log")
    await writeFile(join(legacyData, "data-upgrade.json"), "legacy upgrade")
    for (const suffix of ["", "-shm", "-wal"]) {
      await writeFile(join(legacyData, `herdman-server.sqlite${suffix}`), `database${suffix}`)
    }

    await migrateLegacyLayout({
      databasePath: join(data, "codevisor-server.sqlite"),
      worktreesRoot: join(home, "codevisor"),
      homeDirectory: home
    })

    await expect(readFile(join(data, "server-herdman.log"), "utf8")).resolves.toBe("legacy log")
    await expect(readFile(join(data, "data-upgrade-herdman.json"), "utf8")).resolves.toBe(
      "legacy upgrade"
    )
    for (const suffix of ["", "-shm", "-wal"]) {
      await expect(readFile(join(data, `codevisor-server.sqlite${suffix}`), "utf8")).resolves.toBe(
        `database${suffix}`
      )
    }
  })

  it("repairs Git administration pointers after moving linked worktrees", async () => {
    const home = await mkdtemp(join(tmpdir(), "codevisor-layout-git-"))
    const repository = join(home, "repository")
    const legacyWorktree = join(home, "herdman", "project", "feature")
    const worktrees = join(home, "codevisor")
    await mkdir(repository, { recursive: true })
    await execFileAsync("git", ["init"], { cwd: repository })
    await execFileAsync("git", ["config", "user.email", "tests@codevisor.dev"], {
      cwd: repository
    })
    await execFileAsync("git", ["config", "user.name", "Codevisor Tests"], { cwd: repository })
    await writeFile(join(repository, "README.md"), "test")
    await execFileAsync("git", ["add", "README.md"], { cwd: repository })
    await execFileAsync("git", ["commit", "-m", "Initial commit"], { cwd: repository })
    await mkdir(join(home, "herdman", "project"), { recursive: true })
    await execFileAsync("git", ["worktree", "add", "-b", "feature", legacyWorktree], {
      cwd: repository
    })

    await migrateLegacyLayout({
      databasePath: join(home, ".codevisor", "codevisor-server.sqlite"),
      worktreesRoot: worktrees,
      homeDirectory: home
    })

    const movedWorktree = join(worktrees, "project", "feature")
    const canonicalMovedWorktree = await realpath(movedWorktree)
    const canonicalLegacyWorktree = legacyWorktree.replace(/^\/var\//, "/private/var/")
    const { stdout } = await execFileAsync("git", ["worktree", "list", "--porcelain"], {
      cwd: repository
    })
    expect(stdout).toContain(`worktree ${canonicalMovedWorktree}`)
    expect(stdout).not.toContain(`worktree ${canonicalLegacyWorktree}`)
    await expect(
      execFileAsync("git", ["status", "--short"], { cwd: movedWorktree })
    ).resolves.toMatchObject({ stdout: "" })
  })

  it("repairs a worktree moved by an interrupted previous migration", async () => {
    const home = await mkdtemp(join(tmpdir(), "codevisor-layout-interrupted-"))
    const repository = join(home, "repository")
    const legacyRoot = join(home, "herdman")
    const legacyWorktree = join(legacyRoot, "project", "feature")
    const worktrees = join(home, "codevisor")
    await mkdir(repository, { recursive: true })
    await execFileAsync("git", ["init"], { cwd: repository })
    await execFileAsync("git", ["config", "user.email", "tests@codevisor.dev"], {
      cwd: repository
    })
    await execFileAsync("git", ["config", "user.name", "Codevisor Tests"], { cwd: repository })
    await writeFile(join(repository, "README.md"), "test")
    await execFileAsync("git", ["add", "README.md"], { cwd: repository })
    await execFileAsync("git", ["commit", "-m", "Initial commit"], { cwd: repository })
    await mkdir(join(legacyRoot, "project"), { recursive: true })
    await execFileAsync("git", ["worktree", "add", "-b", "feature", legacyWorktree], {
      cwd: repository
    })
    await rename(legacyRoot, worktrees)
    await writeFile(join(worktrees, "not-a-project"), "skip")
    await writeFile(join(worktrees, "project", "not-a-worktree"), "skip")
    await mkdir(join(worktrees, "project", "missing-git"))
    await mkdir(join(worktrees, "project", "git-directory", ".git"), { recursive: true })
    await mkdir(join(worktrees, "project", "missing-back-pointer"))
    await writeFile(
      join(worktrees, "project", "missing-back-pointer", ".git"),
      `gitdir: ${join(home, "missing-admin")}`
    )

    await migrateLegacyLayout({
      databasePath: join(home, ".codevisor", "codevisor-server.sqlite"),
      worktreesRoot: worktrees,
      homeDirectory: home
    })

    const movedWorktree = join(worktrees, "project", "feature")
    const { stdout } = await execFileAsync("git", ["worktree", "list", "--porcelain"], {
      cwd: repository
    })
    expect(stdout).toContain(`worktree ${await realpath(movedWorktree)}`)
    await expect(
      execFileAsync("git", ["status", "--short"], { cwd: movedWorktree })
    ).resolves.toMatchObject({ stdout: "" })

    // A completed repair is idempotent and exercises the valid-pointer scan.
    await migrateLegacyLayout({
      databasePath: join(home, ".codevisor", "codevisor-server.sqlite"),
      worktreesRoot: worktrees,
      homeDirectory: home
    })
  })

  it("does not move production worktrees into an overridden development root", async () => {
    const home = await mkdtemp(join(tmpdir(), "codevisor-layout-development-"))
    const legacyWorktree = join(home, "herdman", "project", "feature")
    const developmentRoot = join(home, "codevisor-development", "test-instance")
    await mkdir(legacyWorktree, { recursive: true })
    await writeFile(join(legacyWorktree, "progress.txt"), "keep me")

    await migrateLegacyLayout({
      databasePath: join(home, "Codevisor Development", "test-instance", "codevisor-server.sqlite"),
      worktreesRoot: developmentRoot,
      homeDirectory: home
    })

    await expect(readFile(join(legacyWorktree, "progress.txt"), "utf8")).resolves.toBe("keep me")
    await expect(
      readFile(join(developmentRoot, "project", "feature", "progress.txt"), "utf8")
    ).rejects.toMatchObject({ code: "ENOENT" })
  })

  it("uses the system home safely when neither path matches a production layout", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-layout-default-home-"))
    await migrateLegacyLayout({
      databasePath: join(root, "herdman-server.sqlite"),
      worktreesRoot: join(root, "custom-worktrees")
    })
  })
})
