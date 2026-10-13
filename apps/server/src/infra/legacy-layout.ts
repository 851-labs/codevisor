import { execFile } from "node:child_process"
import { createHash } from "node:crypto"
import { createReadStream } from "node:fs"
import {
  cp,
  lstat,
  mkdir,
  readFile,
  readdir,
  readlink,
  realpath,
  rename,
  rm,
  rmdir,
  writeFile
} from "node:fs/promises"
import { tmpdir } from "node:os"
import { basename, dirname, join, relative, resolve, sep } from "node:path"
import { promisify } from "node:util"

import type { DataUpgradeProgress } from "@codevisor/api"

const execFileAsync = promisify(execFile)

export interface LegacyLayoutMigrationOptions {
  readonly databasePath: string
  readonly worktreesRoot: string
  readonly homeDirectory: string
  readonly onProgress?: (progress: DataUpgradeProgress) => void
  /// Receives worktrees whose Git links could not be repaired.
  readonly log: (message: string) => void
}

const migrationId = "codevisor-file-layout-v1"
/// Written to the data directory once moved worktrees have been repaired, so
/// later boots skip rescanning every worktree for an interrupted repair.
const worktreeRepairMarker = `${migrationId}.json`
const migrationName = "Moving HerdMan data to Codevisor"

const pathExists = async (path: string): Promise<boolean> => {
  try {
    await lstat(path)
    return true
  } catch (error) {
    /* v8 ignore next -- the non-ENOENT branch is the unexpected adapter failure surfaced below. */
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false
    /* v8 ignore next -- unexpected lstat failures are surfaced unchanged by the filesystem adapter. */
    throw error
  }
}

const fileHash = async (path: string): Promise<string> => {
  const hash = createHash("sha256")
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return hash.digest("hex")
}

const sameFile = async (left: string, right: string): Promise<boolean> => {
  const [leftStat, rightStat] = await Promise.all([lstat(left), lstat(right)])
  if (leftStat.size !== rightStat.size) return false
  const [leftHash, rightHash] = await Promise.all([fileHash(left), fileHash(right)])
  return leftHash === rightHash
}

const moveWithoutOverwrite = async (source: string, destination: string): Promise<void> => {
  const sourceStat = await lstat(source)
  if (!(await pathExists(destination))) {
    await mkdir(dirname(destination), { recursive: true })
    try {
      await rename(source, destination)
      return
      /* v8 ignore start -- EXDEV requires source and destination on separate mounted filesystems. */
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EXDEV") throw error
      await cp(source, destination, {
        recursive: sourceStat.isDirectory(),
        preserveTimestamps: true
      })
      await rm(source, { recursive: sourceStat.isDirectory(), force: true })
      return
    }
    /* v8 ignore stop */
  }

  const destinationStat = await lstat(destination)
  if (sourceStat.isDirectory() && destinationStat.isDirectory()) {
    for (const entry of await readdir(source)) {
      await moveWithoutOverwrite(join(source, entry), join(destination, entry))
    }
    await rmdir(source)
    return
  }

  if (sourceStat.isSymbolicLink() && destinationStat.isSymbolicLink()) {
    const [sourceTarget, destinationTarget] = await Promise.all([
      readlink(source),
      readlink(destination)
    ])
    if (sourceTarget === destinationTarget) {
      await rm(source)
      return
    }
  } else if (
    sourceStat.isFile() &&
    destinationStat.isFile() &&
    (await sameFile(source, destination))
  ) {
    await rm(source)
    return
  }

  throw new Error(
    `Can't move ${source} because ${destination} already exists with different contents. ` +
      "Move or back up one of the files, then retry the update."
  )
}

export interface TmpDataDirMigrationOptions {
  readonly databasePath: string
  readonly temporaryDirectory?: string
}

/// Everything the server writes next to its database. Standalone installs
/// before the canonical ~/.codevisor/data layout defaulted the database into
/// the OS temp directory (wiped on reboot), so the first start with the new
/// default relocates whatever survived.
const dataDirArtifacts = [
  "codevisor-server.sqlite",
  "codevisor-server.sqlite-shm",
  "codevisor-server.sqlite-wal",
  "data-upgrade.json",
  "attachments",
  "server-updates",
  "harness-profiles",
  "harness-secrets",
  "mcp-secret-key"
] as const

export const migrateTmpDataDir = async (options: TmpDataDirMigrationOptions): Promise<void> => {
  /* v8 ignore next -- tests always inject a temp directory; exercising the real tmpdir() could move a developer's live database. */
  const temporaryDirectory = options.temporaryDirectory ?? tmpdir()
  const dataDirectory = dirname(options.databasePath)
  const legacyDatabasePath = join(temporaryDirectory, "codevisor-server.sqlite")
  if (resolve(legacyDatabasePath) === resolve(options.databasePath)) return
  if (await pathExists(options.databasePath)) return
  if (!(await pathExists(legacyDatabasePath))) return

  for (const artifact of dataDirArtifacts) {
    const source = join(temporaryDirectory, artifact)
    if (await pathExists(source)) {
      await moveWithoutOverwrite(source, join(dataDirectory, artifact))
    }
  }
}

const legacyDataDirectories = (
  databasePath: string,
  homeDirectory: string
): ReadonlyArray<string> => {
  const dataDirectory = dirname(databasePath)
  const candidates = new Set<string>()
  if (basename(dataDirectory) === "Codevisor") {
    candidates.add(join(dirname(dataDirectory), "HerdMan"))
  }
  const dotCodevisor = join(homeDirectory, ".codevisor")
  if (dataDirectory === dotCodevisor || dataDirectory.startsWith(`${dotCodevisor}/`)) {
    candidates.add(dataDirectory.replace(dotCodevisor, join(homeDirectory, ".herdman")))
  }
  return [...candidates]
}

interface SubmoduleWorktreeRepair {
  readonly configPath: string
  readonly worktreePath: string
}

/// Reads a submodule's `core.worktree`, or undefined when it is unset. Git
/// clears the key on `git submodule deinit`, leaving no checkout to repair.
const configuredSubmoduleWorktree = async (configPath: string): Promise<string | undefined> => {
  try {
    const { stdout } = await execFileAsync("git", [
      "config",
      "--file",
      configPath,
      "--get",
      "core.worktree"
    ])
    return stdout.trim()
  } catch (error) {
    if ((error as { readonly code?: unknown }).code === 1) return undefined
    throw error
  }
}

const submoduleWorktreesNeedingRepair = async (
  gitFile: string,
  legacyWorktreesRoot: string,
  canonicalWorktreesRoot: string
): Promise<ReadonlyArray<SubmoduleWorktreeRepair>> => {
  const adminDirectory = resolve(
    dirname(gitFile),
    (await readFile(gitFile, "utf8")).trim().replace(/^gitdir:\s*/, "")
  )
  const modulesDirectory = join(adminDirectory, "modules")
  if (!(await pathExists(modulesDirectory))) return []

  const repairs: SubmoduleWorktreeRepair[] = []
  for (const entry of await readdir(modulesDirectory, { recursive: true })) {
    if (basename(entry) !== "config") continue
    const configPath = join(modulesDirectory, entry)
    const worktree = await configuredSubmoduleWorktree(configPath)
    if (worktree === undefined) continue
    const configuredWorktree = resolve(dirname(configPath), worktree)
    const legacyRelativePath = relative(legacyWorktreesRoot, configuredWorktree)
    if (
      legacyRelativePath === ".." ||
      legacyRelativePath.startsWith(`..${sep}`) ||
      resolve(legacyWorktreesRoot, legacyRelativePath) !== configuredWorktree
    ) {
      continue
    }
    repairs.push({
      configPath,
      worktreePath: resolve(canonicalWorktreesRoot, legacyRelativePath)
    })
  }
  return repairs
}

const linkedWorktreeGitFiles = async (root: string): Promise<ReadonlyArray<string>> => {
  if (!(await pathExists(root))) return []
  const gitFiles: string[] = []
  for (const project of await readdir(root, { withFileTypes: true })) {
    if (!project.isDirectory()) continue
    const projectDirectory = join(root, project.name)
    for (const worktree of await readdir(projectDirectory, { withFileTypes: true })) {
      if (!worktree.isDirectory()) continue
      const gitFile = join(projectDirectory, worktree.name, ".git")
      if ((await pathExists(gitFile)) && (await lstat(gitFile)).isFile()) gitFiles.push(gitFile)
    }
  }
  return gitFiles
}

const worktreeNeedsRepair = async (
  gitFile: string,
  legacyWorktreesRoot: string,
  canonicalWorktreesRoot: string
): Promise<boolean> => {
  const adminDirectory = resolve(
    dirname(gitFile),
    (await readFile(gitFile, "utf8")).trim().replace(/^gitdir:\s*/, "")
  )
  const backPointer = join(adminDirectory, "gitdir")
  if (!(await pathExists(backPointer))) return false
  const storedGitFile = resolve(dirname(backPointer), (await readFile(backPointer, "utf8")).trim())
  const pointsToGitFile =
    (await pathExists(storedGitFile)) &&
    (await realpath(storedGitFile)) === (await realpath(gitFile))
  return (
    !pointsToGitFile ||
    (await submoduleWorktreesNeedingRepair(gitFile, legacyWorktreesRoot, canonicalWorktreesRoot))
      .length > 0
  )
}

const worktreeRepairPending = async (
  root: string,
  legacyWorktreesRoot: string,
  canonicalWorktreesRoot: string
): Promise<boolean> => {
  for (const gitFile of await linkedWorktreeGitFiles(root)) {
    // A worktree that can't be inspected is left to the repair pass, which reports it.
    const pending = await worktreeNeedsRepair(
      gitFile,
      legacyWorktreesRoot,
      canonicalWorktreesRoot
    ).catch(() => true)
    if (pending) return true
  }
  return false
}

/// Repairs each moved worktree independently. A worktree Git can't repair is
/// reported and skipped: its files are already in place, and one broken
/// checkout must not keep the server from starting.
const repairMovedWorktrees = async (
  root: string,
  legacyWorktreesRoot: string,
  canonicalWorktreesRoot: string,
  log: (message: string) => void
): Promise<void> => {
  for (const gitFile of await linkedWorktreeGitFiles(root)) {
    const worktree = dirname(gitFile)
    try {
      if (!(await worktreeNeedsRepair(gitFile, legacyWorktreesRoot, canonicalWorktreesRoot))) {
        continue
      }
      await execFileAsync("git", ["-C", worktree, "worktree", "repair", worktree])
      for (const repair of await submoduleWorktreesNeedingRepair(
        gitFile,
        legacyWorktreesRoot,
        canonicalWorktreesRoot
      )) {
        await execFileAsync("git", [
          "config",
          "--file",
          repair.configPath,
          "core.worktree",
          repair.worktreePath
        ])
      }
    } catch (error) {
      /* v8 ignore next -- Node filesystem and git failures use Error instances. */
      const message = error instanceof Error ? error.message : String(error)
      log(`Skipped repairing Git links for ${worktree}: ${message}`)
    }
  }
}

const report = (
  onProgress: LegacyLayoutMigrationOptions["onProgress"],
  state: DataUpgradeProgress["state"],
  completed: number,
  total: number,
  error?: string
): void => {
  onProgress?.({
    state,
    id: migrationId,
    name: migrationName,
    completed,
    total,
    ...(error === undefined ? {} : { error })
  })
}

/// Moves the pre-Codevisor data layout before the database opens. This is a
/// blocking update backfill: the server health endpoint intentionally remains
/// unavailable until every file and worktree is safely in its new location.
/// Repairing Git links in moved worktrees is best-effort and runs until the
/// data directory records it as complete.
export const migrateLegacyLayout = async (options: LegacyLayoutMigrationOptions): Promise<void> => {
  const { homeDirectory } = options
  const dataDirectory = dirname(options.databasePath)
  const legacyWorktreesRoot = join(homeDirectory, "herdman")
  const canonicalWorktreesRoot = join(homeDirectory, "codevisor")
  const canonicalHomeDirectory = await realpath(homeDirectory)
  const canonicalLegacyWorktreesRoot = join(canonicalHomeDirectory, "herdman")
  const canonicalCodevisorWorktreesRoot = join(canonicalHomeDirectory, "codevisor")
  const operations: Array<() => Promise<void>> = []
  const legacyDirectories = legacyDataDirectories(options.databasePath, homeDirectory)

  for (const legacyDirectory of legacyDirectories) {
    if (await pathExists(legacyDirectory)) {
      for (const [legacyName, archiveName] of [
        ["server.log", "server-herdman.log"],
        ["data-upgrade.json", "data-upgrade-herdman.json"]
      ] as const) {
        const source = join(legacyDirectory, legacyName)
        if (await pathExists(source)) {
          operations.push(() => moveWithoutOverwrite(source, join(dataDirectory, archiveName)))
        }
      }
      operations.push(() => moveWithoutOverwrite(legacyDirectory, dataDirectory))
    }
  }

  for (const suffix of ["", "-shm", "-wal"]) {
    const source = join(dataDirectory, `herdman-server.sqlite${suffix}`)
    const destination = `${options.databasePath}${suffix}`
    const existsBeforeMerge =
      (await pathExists(source)) ||
      (
        await Promise.all(
          legacyDirectories.map((directory) =>
            pathExists(join(directory, `herdman-server.sqlite${suffix}`))
          )
        )
      ).some(Boolean)
    if (source !== destination && existsBeforeMerge) {
      operations.push(async () => {
        /* v8 ignore next -- defensive recheck for a file removed by another interrupted updater. */
        if (await pathExists(source)) await moveWithoutOverwrite(source, destination)
      })
    }
  }

  const { log } = options
  const managesWorktrees = options.worktreesRoot === canonicalWorktreesRoot
  const repairMarker = join(dataDirectory, worktreeRepairMarker)
  const repairRecorded = await pathExists(repairMarker)
  const recordRepairComplete = async (): Promise<void> => {
    if (!managesWorktrees || repairRecorded) return
    await mkdir(dataDirectory, { recursive: true })
    await writeFile(repairMarker, `${JSON.stringify({ id: migrationId })}\n`)
  }

  if (managesWorktrees && (await pathExists(legacyWorktreesRoot))) {
    operations.push(async () => {
      await moveWithoutOverwrite(legacyWorktreesRoot, options.worktreesRoot)
      await repairMovedWorktrees(
        options.worktreesRoot,
        canonicalLegacyWorktreesRoot,
        canonicalCodevisorWorktreesRoot,
        log
      )
    })
  } else if (
    managesWorktrees &&
    !repairRecorded &&
    (await worktreeRepairPending(
      options.worktreesRoot,
      canonicalLegacyWorktreesRoot,
      canonicalCodevisorWorktreesRoot
    ))
  ) {
    // A previous attempt may have moved the files before it was interrupted.
    operations.push(() =>
      repairMovedWorktrees(
        options.worktreesRoot,
        canonicalLegacyWorktreesRoot,
        canonicalCodevisorWorktreesRoot,
        log
      )
    )
  }

  if (operations.length === 0) {
    await recordRepairComplete()
    return
  }
  let completed = 0
  report(options.onProgress, "running", completed, operations.length)
  try {
    for (const operation of operations) {
      await operation()
      completed += 1
      report(options.onProgress, "running", completed, operations.length)
    }
    await recordRepairComplete()
    report(options.onProgress, "completed", operations.length, operations.length)
  } catch (error) {
    /* v8 ignore next -- Node filesystem and git failures use Error instances. */
    const message = error instanceof Error ? error.message : String(error)
    report(options.onProgress, "failed", completed, operations.length, message)
    throw error
  }
}
