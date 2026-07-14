import { createHash } from "node:crypto"
import { execFile } from "node:child_process"
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
  rmdir
} from "node:fs/promises"
import { homedir } from "node:os"
import { basename, dirname, join, relative, resolve, sep } from "node:path"
import { promisify } from "node:util"
import type { DataUpgradeProgress } from "@codevisor/api"

const execFileAsync = promisify(execFile)

export interface LegacyLayoutMigrationOptions {
  readonly databasePath: string
  readonly worktreesRoot: string
  readonly homeDirectory?: string
  readonly onProgress?: (progress: DataUpgradeProgress) => void
}

const migrationId = "codevisor-file-layout-v1"
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
    const { stdout } = await execFileAsync("git", [
      "config",
      "--file",
      configPath,
      "--get",
      "core.worktree"
    ])
    const configuredWorktree = resolve(dirname(configPath), stdout.trim())
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

const worktreesNeedingRepair = async (
  root: string,
  legacyWorktreesRoot: string,
  canonicalWorktreesRoot: string
): Promise<ReadonlyArray<string>> => {
  if (!(await pathExists(root))) return []
  const worktrees: string[] = []

  for (const project of await readdir(root, { withFileTypes: true })) {
    if (!project.isDirectory()) continue
    const projectDirectory = join(root, project.name)
    for (const worktree of await readdir(projectDirectory, { withFileTypes: true })) {
      if (!worktree.isDirectory()) continue
      const worktreeDirectory = join(projectDirectory, worktree.name)
      const gitFile = join(worktreeDirectory, ".git")
      if (!(await pathExists(gitFile)) || !(await lstat(gitFile)).isFile()) continue

      const adminDirectory = resolve(
        dirname(gitFile),
        (await readFile(gitFile, "utf8")).trim().replace(/^gitdir:\s*/, "")
      )
      const backPointer = join(adminDirectory, "gitdir")
      if (!(await pathExists(backPointer))) continue
      const storedGitFile = resolve(
        dirname(backPointer),
        (await readFile(backPointer, "utf8")).trim()
      )
      let pointsToGitFile = false
      if (await pathExists(storedGitFile)) {
        pointsToGitFile = (await realpath(storedGitFile)) === (await realpath(gitFile))
      }
      const submoduleRepairs = await submoduleWorktreesNeedingRepair(
        gitFile,
        legacyWorktreesRoot,
        canonicalWorktreesRoot
      )
      if (!pointsToGitFile || submoduleRepairs.length > 0) {
        worktrees.push(worktreeDirectory)
      }
    }
  }

  return worktrees
}

const repairMovedWorktrees = async (
  root: string,
  legacyWorktreesRoot: string,
  canonicalWorktreesRoot: string
): Promise<void> => {
  for (const worktree of await worktreesNeedingRepair(
    root,
    legacyWorktreesRoot,
    canonicalWorktreesRoot
  )) {
    await execFileAsync("git", ["-C", worktree, "worktree", "repair", worktree])
    for (const repair of await submoduleWorktreesNeedingRepair(
      join(worktree, ".git"),
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
export const migrateLegacyLayout = async (options: LegacyLayoutMigrationOptions): Promise<void> => {
  const homeDirectory = options.homeDirectory ?? homedir()
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

  if (options.worktreesRoot === canonicalWorktreesRoot && (await pathExists(legacyWorktreesRoot))) {
    operations.push(async () => {
      await moveWithoutOverwrite(legacyWorktreesRoot, options.worktreesRoot)
      await repairMovedWorktrees(
        options.worktreesRoot,
        canonicalLegacyWorktreesRoot,
        canonicalCodevisorWorktreesRoot
      )
    })
  } else if (
    options.worktreesRoot === canonicalWorktreesRoot &&
    (
      await worktreesNeedingRepair(
        options.worktreesRoot,
        canonicalLegacyWorktreesRoot,
        canonicalCodevisorWorktreesRoot
      )
    ).length > 0
  ) {
    // A previous attempt may have moved the files before it was interrupted.
    operations.push(() =>
      repairMovedWorktrees(
        options.worktreesRoot,
        canonicalLegacyWorktreesRoot,
        canonicalCodevisorWorktreesRoot
      )
    )
  }

  if (operations.length === 0) return
  let completed = 0
  report(options.onProgress, "running", completed, operations.length)
  try {
    for (const operation of operations) {
      await operation()
      completed += 1
      report(options.onProgress, "running", completed, operations.length)
    }
    report(options.onProgress, "completed", operations.length, operations.length)
  } catch (error) {
    /* v8 ignore next -- Node filesystem and git failures use Error instances. */
    const message = error instanceof Error ? error.message : String(error)
    report(options.onProgress, "failed", completed, operations.length, message)
    throw error
  }
}
