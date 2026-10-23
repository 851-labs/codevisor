import type { Dirent } from "node:fs"
import { lstat, mkdir, readdir, rename, rm } from "node:fs/promises"
import { dirname, join } from "node:path"

import { runGit } from "./git.js"
import { heavyGit as heavy, scratchIndexConfig as gitConfig } from "./working-state.js"

const rebuildablePattern =
  /(^|\/)(node_modules|\.venv|venv|__pycache__|target|dist|build|\.build|DerivedData|\.cache|out|\.next|\.turbo|\.gradle|\.pytest_cache|coverage|\.DS_Store)(\/|$)/

export const meaningfulIgnoredPaths = (paths: ReadonlyArray<string>): ReadonlyArray<string> =>
  paths.filter((path) => !rebuildablePattern.test(path))

export const listKeptArtifacts = async (
  worktreeDir: string,
  env?: NodeJS.ProcessEnv
): Promise<ReadonlyArray<string>> => {
  try {
    return meaningfulIgnoredPaths(nulSeparated(await listIgnoredPaths(worktreeDir, env)))
  } catch {
    return []
  }
}

export const keepArtifacts = async (
  worktreeDir: string,
  artifactsDir: string,
  env?: NodeJS.ProcessEnv
): Promise<ReadonlyArray<string>> => {
  const kept = await listKeptArtifacts(worktreeDir, env)
  for (const path of kept) await moveInto(join(worktreeDir, path), join(artifactsDir, path))
  return kept
}

export const returnKeptArtifacts = async (
  artifactsDir: string,
  worktreeDir: string
): Promise<void> => {
  await moveMissingEntries(artifactsDir, worktreeDir)
  await rm(artifactsDir, { recursive: true, force: true })
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

const moveInto = async (source: string, target: string): Promise<void> => {
  await mkdir(dirname(target), { recursive: true })
  await rename(source, target)
}

const moveMissingEntries = async (from: string, to: string): Promise<void> => {
  const entries = await readdir(from, { withFileTypes: true }).catch((): Array<Dirent> => [])
  for (const entry of entries)
    await moveIfMissing(entry, join(from, entry.name), join(to, entry.name))
}

const moveIfMissing = async (entry: Dirent, source: string, target: string): Promise<void> => {
  const existing = await lstat(target).catch(() => undefined)
  if (existing === undefined) return rename(source, target)
  if (entry.isDirectory() && existing.isDirectory()) return moveMissingEntries(source, target)
}
