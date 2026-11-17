import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { gitCurrentBranch, runGit } from "./git.js"
import { heavyGit } from "./working-state.js"
import { snapshotRefFor, snapshotWorktree } from "./worktree-archive.js"

export interface SavedWork {
  readonly branch?: string
  readonly head: string
  readonly snapshot: string
  readonly bundle: Buffer
}

const savedWorkRef = snapshotRefFor("saved-work")

export const saveWork = async (repoDir: string, env?: NodeJS.ProcessEnv): Promise<SavedWork> => {
  const branch = await gitCurrentBranch(repoDir, env ?? process.env)
  const saved = await snapshotWorktree(repoDir, repoDir, "saved-work", env)
  const bundle = await withBundleFile(async (file) => {
    await runGit(
      "bundle-create",
      ["bundle", "create", file, savedWorkRef, "--not", "--remotes"],
      repoDir,
      env,
      heavyGit
    )
    return readFile(file)
  })
  return {
    ...(branch === null ? {} : { branch }),
    head: saved.parentSha,
    snapshot: saved.snapshotSha,
    bundle
  }
}

export const restoreSavedWork = async (
  repoDir: string,
  work: SavedWork,
  env?: NodeJS.ProcessEnv
): Promise<void> => {
  await withBundleFile(async (file) => {
    await writeFile(file, work.bundle)
    await runGit(
      "bundle-fetch",
      ["fetch", "--no-tags", file, `+${savedWorkRef}:${savedWorkRef}`],
      repoDir,
      env,
      heavyGit
    )
  })
  const checkout =
    work.branch === undefined ? ["--detach", work.head] : ["-B", work.branch, work.head]
  await runGit("checkout-saved-head", ["checkout", ...checkout], repoDir, env)
  await runGit(
    "read-tree",
    ["read-tree", "-u", "--reset", `${work.snapshot}^{tree}`],
    repoDir,
    env,
    heavyGit
  )
  await runGit("reset-mixed", ["reset", "--mixed", work.head], repoDir, env)
  if (work.branch !== undefined) await trackPushedBranch(repoDir, work.branch, env)
}

const trackPushedBranch = async (
  repoDir: string,
  branch: string,
  env: NodeJS.ProcessEnv | undefined
): Promise<void> => {
  await runGit(
    "track-pushed-branch",
    ["branch", `--set-upstream-to=origin/${branch}`, branch],
    repoDir,
    env
  ).catch(() => undefined)
}

const withBundleFile = async <A>(work: (file: string) => Promise<A>): Promise<A> => {
  const dir = await mkdtemp(join(tmpdir(), "codevisor-saved-work-"))
  try {
    return await work(join(dir, "work.bundle"))
  } finally {
    await rm(dir, { force: true, recursive: true })
  }
}
