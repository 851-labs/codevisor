import { existsSync, type Dirent } from "node:fs"
import { lstat, mkdir, readdir, rename, rm, rmdir, writeFile } from "node:fs/promises"
import { basename, dirname, join, relative, sep } from "node:path"

import { runGit } from "./git.js"
import { heavyGit as heavy, scratchIndexConfig as gitConfig } from "./working-state.js"

const rebuildableNames = [
  "node_modules",
  ".venv",
  "venv",
  "__pycache__",
  "target",
  "dist",
  "build",
  ".build",
  "DerivedData",
  ".cache",
  "out",
  ".next",
  ".turbo",
  ".gradle",
  ".pytest_cache",
  "coverage",
  ".DS_Store"
]

const rebuildablePattern = new RegExp(
  `(^|/)(${rebuildableNames.map((name) => name.replaceAll(".", "\\.")).join("|")})(/|$)`
)

export const meaningfulIgnoredPaths = (paths: ReadonlyArray<string>): ReadonlyArray<string> =>
  paths.filter((path) => !rebuildablePattern.test(path))

export const listKeptArtifacts = async (
  worktreeDir: string,
  env?: NodeJS.ProcessEnv
): Promise<ReadonlyArray<string>> => {
  if (!existsSync(worktreeDir)) return []
  return topMostPaths(
    meaningfulIgnoredPaths(nulSeparated(await listIgnoredPaths(worktreeDir, env)))
  )
}

export const keepArtifacts = async (
  worktreeDir: string,
  artifactsDir: string,
  env?: NodeJS.ProcessEnv
): Promise<ReadonlyArray<string>> => {
  const kept = await listKeptArtifacts(worktreeDir, env)
  const moved: Array<string> = []
  try {
    for (const path of kept) {
      await moveInto(join(worktreeDir, path), join(artifactsDir, path))
      moved.push(path)
    }
    for (const path of kept) await pruneRebuildable(join(artifactsDir, path))
  } catch (error) {
    await putBack(moved, artifactsDir, worktreeDir)
    throw error
  }
  return kept
}

export const restoreConflictsFolder = ".codevisor-restore-conflicts"

export const returnKeptArtifacts = async (
  artifactsDir: string,
  worktreeDir: string
): Promise<ReadonlyArray<string>> => {
  if (!existsSync(artifactsDir)) return []
  const conflicts = await moveMissingEntries(artifactsDir, worktreeDir, "")
  const setAside = []
  for (const path of conflicts) setAside.push(await moveAside(artifactsDir, worktreeDir, path))
  await rm(artifactsDir, { recursive: true, force: true })
  return setAside
}

const listIgnoredPaths = (worktreeDir: string, env?: NodeJS.ProcessEnv): Promise<string> =>
  runGit(
    "list-ignored",
    [...gitConfig, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"],
    worktreeDir,
    env,
    heavy
  )

const nulSeparated = (output: string): ReadonlyArray<string> =>
  output.split("\0").filter((path) => path.length > 0)

const topMostPaths = (paths: ReadonlyArray<string>): ReadonlyArray<string> => {
  const topMost: Array<string> = []
  for (const path of paths.toSorted()) {
    if (!isInside(path, topMost.at(-1))) topMost.push(path)
  }
  return topMost
}

const isInside = (path: string, folder: string | undefined): boolean =>
  folder !== undefined && folder.endsWith("/") && path.startsWith(folder)

const putBack = async (
  moved: ReadonlyArray<string>,
  artifactsDir: string,
  worktreeDir: string
): Promise<void> => {
  await Promise.allSettled(
    moved.map((path) => moveInto(join(artifactsDir, path), join(worktreeDir, path)))
  )
  await removeEmptyFolders(artifactsDir)
}

const removeEmptyFolders = async (path: string): Promise<void> => {
  if (!existsSync(path)) return
  for (const entry of await readdir(path, { withFileTypes: true })) {
    if (entry.isDirectory()) await removeEmptyFolders(join(path, entry.name))
  }
  await rmdir(path).catch(() => undefined)
}

const moveInto = async (source: string, target: string): Promise<void> => {
  await mkdir(dirname(target), { recursive: true })
  await rename(source, target)
}

const moveMissingEntries = async (
  from: string,
  to: string,
  under: string
): Promise<ReadonlyArray<string>> => {
  const entries = await readdir(from, { withFileTypes: true })
  const unrestored: Array<string> = []
  for (const entry of entries) {
    const path = join(under, entry.name)
    unrestored.push(
      ...(await moveIfMissing(entry, join(from, entry.name), join(to, entry.name), path))
    )
  }
  if (unrestored.length === 0) await rmdir(from)
  return unrestored
}

const moveIfMissing = async (
  entry: Dirent,
  source: string,
  target: string,
  path: string
): Promise<ReadonlyArray<string>> => {
  const existing = await lstat(target).catch(() => undefined)
  if (existing === undefined) {
    await moveInto(source, target)
    return []
  }
  if (entry.isDirectory() && existing.isDirectory()) return moveMissingEntries(source, target, path)
  return [path]
}

const moveAside = async (
  artifactsDir: string,
  worktreeDir: string,
  path: string
): Promise<string> => {
  const folder = join(worktreeDir, restoreConflictsFolder)
  await refuseSymlinkedPath(worktreeDir, join(folder, path))
  await mkdir(folder, { recursive: true })
  await writeFile(join(folder, ".gitignore"), "*\n")
  const target = await unusedPath(join(folder, path))
  await refuseSymlinkedPath(worktreeDir, target)
  await moveInto(join(artifactsDir, path), target)
  return relative(worktreeDir, target)
}

const refuseSymlinkedPath = async (root: string, target: string): Promise<void> => {
  let current = root
  for (const part of relative(root, target).split(sep)) {
    current = join(current, part)
    const stats = await lstat(current).catch(() => undefined)
    if (stats === undefined) return
    if (stats.isSymbolicLink()) {
      throw new Error(
        `Refusing to restore artifacts through the symlink ${relative(root, current)}`
      )
    }
  }
}

const unusedPath = async (path: string, attempt = 1): Promise<string> => {
  const candidate = attempt === 1 ? path : `${path}-${attempt}`
  if ((await lstat(candidate).catch(() => undefined)) === undefined) return candidate
  return unusedPath(path, attempt + 1)
}

const pruneRebuildable = async (path: string): Promise<void> => {
  const stats = await lstat(path)
  if (!stats.isDirectory()) return
  if (rebuildableNames.includes(basename(path))) {
    await rm(path, { recursive: true, force: true })
    return
  }
  for (const entry of await readdir(path)) await pruneRebuildable(join(path, entry))
}
