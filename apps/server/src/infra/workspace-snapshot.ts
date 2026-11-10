import { lstat, mkdir, readFile, writeFile } from "node:fs/promises"
import { join } from "node:path"

import { git, gitWithInput } from "./sync-git.js"

export const SYNC_FILE_SIZE_LIMIT = 50 * 1024 * 1024

export interface SnapshotRepo {
  readonly gitDir: string
  readonly workTree: string
}

export interface Snapshot {
  readonly tree: string
  readonly skipped: ReadonlyArray<string>
}

export const ensureSnapshotRepo = async (repo: SnapshotRepo): Promise<void> => {
  const initialized = await lstat(join(repo.gitDir, "HEAD")).catch(() => undefined)
  if (initialized !== undefined) return

  await mkdir(repo.gitDir, { recursive: true })
  await git(["init", "--bare", "--quiet", repo.gitDir])
  await git(["--git-dir", repo.gitDir, "config", "core.bare", "false"])
  await git(["--git-dir", repo.gitDir, "config", "core.untrackedCache", "true"])
}

export const takeSnapshot = async (repo: SnapshotRepo): Promise<Snapshot> => {
  const skipped = await excludeLargeFiles(repo)
  await git(["add", "--all"], gitEnv(repo))
  const tree = (await git(["write-tree"], gitEnv(repo))).trim()
  return { tree, skipped }
}

export const commitSnapshot = async (
  repo: SnapshotRepo,
  tree: string,
  parent: string | undefined
): Promise<string> => {
  const parents = parent === undefined ? [] : ["-p", parent]
  const commit = await git(["commit-tree", tree, ...parents, "-m", "Codevisor sync"], {
    env: { ...gitEnv(repo).env, ...SYNC_IDENTITY }
  })
  return commit.trim()
}

export const hasCommit = async (repo: SnapshotRepo, commit: string): Promise<boolean> =>
  git(["--git-dir", repo.gitDir, "cat-file", "-e", `${commit}^{commit}`]).then(
    () => true,
    () => false
  )

export interface PackRange {
  readonly commit: string
  readonly base?: string | undefined
  readonly head?: string | undefined
  readonly baseHead?: string | undefined
}

export const packSince = (repo: SnapshotRepo, range: PackRange): Promise<Buffer> =>
  gitWithInput(
    ["--git-dir", repo.gitDir, "pack-objects", "--revs", "--thin", "--stdout", "--quiet"],
    packRevisions(range)
  )

const packRevisions = (range: PackRange): string => {
  const heads = [range.head, range.baseHead].filter((head) => head !== undefined)
  const wanted = [range.commit, range.head].filter((commit) => commit !== undefined)
  const known = [range.base, range.baseHead].filter((commit) => commit !== undefined)
  const lines = [
    ...heads.map((head) => `--shallow ${head}`),
    ...wanted,
    ...(known.length === 0 ? [] : ["--not", ...known])
  ]
  return `${lines.join("\n")}\n`
}

export const changedFileCount = async (
  repo: SnapshotRepo,
  base: string | undefined,
  commit: string
): Promise<number> => {
  const args =
    base === undefined
      ? ["ls-tree", "-r", "--name-only", commit]
      : ["diff-tree", "-r", "--name-only", "--no-commit-id", base, commit]
  const listed = await git(["--git-dir", repo.gitDir, ...args])
  return listed.split("\n").filter((line) => line.length > 0).length
}

const SYNC_IDENTITY = {
  GIT_AUTHOR_NAME: "Codevisor",
  GIT_AUTHOR_EMAIL: "sync@codevisor.local",
  GIT_COMMITTER_NAME: "Codevisor",
  GIT_COMMITTER_EMAIL: "sync@codevisor.local"
}

const DEFAULT_EXCLUDES = [".DS_Store"]

const gitEnv = (repo: SnapshotRepo) => ({
  env: { GIT_DIR: repo.gitDir, GIT_WORK_TREE: repo.workTree },
  cwd: repo.workTree
})

const excludeLargeFiles = async (repo: SnapshotRepo): Promise<ReadonlyArray<string>> => {
  const listed = await git(["ls-files", "-z", "--others", "--exclude-standard"], gitEnv(repo))
  const candidates = listed.split("\0").filter((path) => path.length > 0)
  const excluded = await writeExcludes(repo, await largeFiles(repo.workTree, candidates))
  return excluded.filter((line) => line.startsWith("/")).map(unanchored)
}

const largeFiles = async (
  workTree: string,
  paths: ReadonlyArray<string>
): Promise<ReadonlyArray<string>> => {
  const large: string[] = []
  for (const path of paths) {
    const info = await lstat(join(workTree, path)).catch(() => undefined)
    if (info !== undefined && info.size > SYNC_FILE_SIZE_LIMIT) large.push(path)
  }
  return large
}

const writeExcludes = async (
  repo: SnapshotRepo,
  large: ReadonlyArray<string>
): Promise<ReadonlyArray<string>> => {
  const path = join(repo.gitDir, "info", "exclude")
  const previous = await readFile(path, "utf8").catch(() => "")
  const excluded = previous.split("\n").filter((line) => line.length > 0)
  const merged = [...new Set([...excluded, ...DEFAULT_EXCLUDES, ...large.map(anchored)])]
  if (merged.length === excluded.length) return merged

  await mkdir(join(repo.gitDir, "info"), { recursive: true })
  await writeFile(path, `${merged.join("\n")}\n`)
  return merged
}

const anchored = (path: string): string => `/${path.replace(/([*?[\\!#])/g, "\\$1")}`

const unanchored = (line: string): string => line.slice(1).replace(/\\(.)/g, "$1")
