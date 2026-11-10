import { mkdir, readFile, realpath, writeFile } from "node:fs/promises"
import { join } from "node:path"

import type { MirrorSourceHead } from "@codevisor/api"

import { git } from "./sync-git.js"
import type { SnapshotRepo } from "./workspace-snapshot.js"

export interface SourceCheckout {
  readonly head: MirrorSourceHead
  readonly objects: string
}

export const sourceCheckout = async (root: string): Promise<SourceCheckout | undefined> => {
  const toplevel = await gitIn(root, ["rev-parse", "--show-toplevel"])
  if (toplevel === undefined || !(await samePath(toplevel, root))) return undefined
  const commit = await gitIn(root, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
  const common = await gitIn(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
  if (commit === undefined || common === undefined) return undefined
  const branch = await gitIn(root, ["symbolic-ref", "--quiet", "--short", "HEAD"])
  return {
    head: branch === undefined ? { commit } : { commit, branch },
    objects: join(common, "objects")
  }
}

export const shareSourceObjects = async (repo: SnapshotRepo, objects: string): Promise<void> => {
  const path = join(repo.gitDir, "objects", "info", "alternates")
  if ((await readFile(path, "utf8").catch(() => "")).trim() === objects) return
  await mkdir(join(repo.gitDir, "objects", "info"), { recursive: true })
  await writeFile(path, `${objects}\n`)
}

const gitIn = async (root: string, args: ReadonlyArray<string>): Promise<string | undefined> => {
  const output = await git(["-C", root, ...args]).catch(() => undefined)
  const trimmed = output?.trim()
  return trimmed === undefined || trimmed === "" ? undefined : trimmed
}

const samePath = async (a: string, b: string): Promise<boolean> => {
  const [first, second] = await Promise.all([realpath(a), realpath(b)])
  return first === second
}
