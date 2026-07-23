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
import { migrateLegacyLayout, migrateTmpDataDir } from "./legacy-layout.js"

const execFileAsync = promisify(execFile)

describe("Codevisor tmp data dir migration", () => {
  it("relocates the database and sidecar state from the temp directory", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-tmp-data-"))
    const temporaryDirectory = join(root, "tmp")
    const dataDirectory = join(root, ".codevisor", "data")
    await mkdir(join(temporaryDirectory, "harness-secrets", "claude-code"), { recursive: true })
    await mkdir(join(temporaryDirectory, "attachments", "objects", "sha256", "ab"), {
      recursive: true
    })
    await writeFile(join(temporaryDirectory, "codevisor-server.sqlite"), "database")
    await writeFile(join(temporaryDirectory, "codevisor-server.sqlite-wal"), "wal")
    await writeFile(join(temporaryDirectory, "mcp-secret-key"), "key")
    await writeFile(join(temporaryDirectory, "harness-secrets", "claude-code", "api-key"), "sk")
    await writeFile(
      join(temporaryDirectory, "attachments", "objects", "sha256", "ab", "abcdef"),
      "attachment"
    )
    await writeFile(join(temporaryDirectory, "unrelated.txt"), "left behind")

    await migrateTmpDataDir({
      databasePath: join(dataDirectory, "codevisor-server.sqlite"),
      temporaryDirectory
    })

    await expect(readFile(join(dataDirectory, "codevisor-server.sqlite"), "utf8")).resolves.toBe(
      "database"
    )
    await expect(
      readFile(join(dataDirectory, "codevisor-server.sqlite-wal"), "utf8")
    ).resolves.toBe("wal")
    await expect(readFile(join(dataDirectory, "mcp-secret-key"), "utf8")).resolves.toBe("key")
    await expect(
      readFile(join(dataDirectory, "harness-secrets", "claude-code", "api-key"), "utf8")
    ).resolves.toBe("sk")
    await expect(
      readFile(join(dataDirectory, "attachments", "objects", "sha256", "ab", "abcdef"), "utf8")
    ).resolves.toBe("attachment")
    await expect(readFile(join(temporaryDirectory, "unrelated.txt"), "utf8")).resolves.toBe(
      "left behind"
    )
    await expect(lstat(join(temporaryDirectory, "codevisor-server.sqlite"))).rejects.toMatchObject({
      code: "ENOENT"
    })
  })

  it("does nothing when the canonical database already exists", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-tmp-data-existing-"))
    const temporaryDirectory = join(root, "tmp")
    const dataDirectory = join(root, ".codevisor", "data")
    await mkdir(temporaryDirectory, { recursive: true })
    await mkdir(dataDirectory, { recursive: true })
    await writeFile(join(temporaryDirectory, "codevisor-server.sqlite"), "stale")
    await writeFile(join(dataDirectory, "codevisor-server.sqlite"), "current")

    await migrateTmpDataDir({
      databasePath: join(dataDirectory, "codevisor-server.sqlite"),
      temporaryDirectory
    })

    await expect(readFile(join(dataDirectory, "codevisor-server.sqlite"), "utf8")).resolves.toBe(
      "current"
    )
    await expect(
      readFile(join(temporaryDirectory, "codevisor-server.sqlite"), "utf8")
    ).resolves.toBe("stale")
  })

  it("does nothing when there is no temp database or the paths coincide", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-tmp-data-noop-"))
    const temporaryDirectory = join(root, "tmp")
    await mkdir(temporaryDirectory, { recursive: true })

    // No temp database at all.
    await migrateTmpDataDir({
      databasePath: join(root, ".codevisor", "data", "codevisor-server.sqlite"),
      temporaryDirectory
    })
    await expect(lstat(join(root, ".codevisor"))).rejects.toMatchObject({ code: "ENOENT" })

    // Database path already inside the temp directory (legacy default).
    await writeFile(join(temporaryDirectory, "codevisor-server.sqlite"), "database")
    await migrateTmpDataDir({
      databasePath: join(temporaryDirectory, "codevisor-server.sqlite"),
      temporaryDirectory
    })
    await expect(
      readFile(join(temporaryDirectory, "codevisor-server.sqlite"), "utf8")
    ).resolves.toBe("database")
  })
})

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
    const submoduleRepository = join(home, "submodule")
    const legacyWorktree = join(home, "herdman", "project", "feature")
    const worktrees = join(home, "codevisor")
    await mkdir(repository, { recursive: true })
    await mkdir(submoduleRepository, { recursive: true })
    await execFileAsync("git", ["init"], { cwd: repository })
    await execFileAsync("git", ["init"], { cwd: submoduleRepository })
    await execFileAsync("git", ["config", "user.email", "tests@codevisor.dev"], {
      cwd: repository
    })
    await execFileAsync("git", ["config", "user.name", "Codevisor Tests"], { cwd: repository })
    await execFileAsync("git", ["config", "user.email", "tests@codevisor.dev"], {
      cwd: submoduleRepository
    })
    await execFileAsync("git", ["config", "user.name", "Codevisor Tests"], {
      cwd: submoduleRepository
    })
    await writeFile(join(submoduleRepository, "SUBMODULE.md"), "submodule")
    await execFileAsync("git", ["add", "SUBMODULE.md"], { cwd: submoduleRepository })
    await execFileAsync("git", ["commit", "-m", "Initial submodule commit"], {
      cwd: submoduleRepository
    })
    await writeFile(join(repository, "README.md"), "test")
    await execFileAsync("git", ["add", "README.md"], { cwd: repository })
    await execFileAsync("git", ["commit", "-m", "Initial commit"], { cwd: repository })
    await execFileAsync(
      "git",
      ["-c", "protocol.file.allow=always", "submodule", "add", submoduleRepository, "deps/sub"],
      { cwd: repository }
    )
    await execFileAsync("git", ["commit", "-am", "Add submodule"], { cwd: repository })
    await mkdir(join(home, "herdman", "project"), { recursive: true })
    await execFileAsync("git", ["worktree", "add", "-b", "feature", legacyWorktree], {
      cwd: repository
    })
    await execFileAsync(
      "git",
      ["-c", "protocol.file.allow=always", "submodule", "update", "--init"],
      { cwd: legacyWorktree }
    )

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
    await expect(
      execFileAsync("git", ["status", "--short"], { cwd: join(movedWorktree, "deps", "sub") })
    ).resolves.toMatchObject({ stdout: "" })

    // A completed submodule repair is idempotent and does not schedule another migration.
    await migrateLegacyLayout({
      databasePath: join(home, ".codevisor", "codevisor-server.sqlite"),
      worktreesRoot: worktrees,
      homeDirectory: home
    })
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
