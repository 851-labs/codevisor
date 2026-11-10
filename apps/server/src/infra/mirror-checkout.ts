import { readFile, writeFile } from "node:fs/promises"
import { join } from "node:path"

import type { MirrorSourceHead } from "@codevisor/api"

import { git } from "./sync-git.js"

export const SYNC_REF = "refs/heads/sync"

export const linkCheckout = async (gitDir: string, workTree: string): Promise<void> => {
  const pointer = join(workTree, ".git")
  const wanted = `gitdir: ${gitDir}\n`
  if ((await readFile(pointer, "utf8").catch(() => undefined)) !== wanted) {
    await writeFile(pointer, wanted)
  }
  await git(["--git-dir", gitDir, "config", "core.bare", "false"])
}

export const pointHead = async (
  gitDir: string,
  head: MirrorSourceHead | undefined
): Promise<void> => {
  if (head === undefined) {
    await git(["--git-dir", gitDir, "symbolic-ref", "HEAD", SYNC_REF])
    return
  }
  await markShallow(gitDir, head.commit)
  const branch = await validBranch(head.branch)
  await dropStaleBranches(gitDir, branch)
  if (branch === undefined) {
    await git(["--git-dir", gitDir, "update-ref", "--no-deref", "HEAD", head.commit])
    return
  }
  await git(["--git-dir", gitDir, "update-ref", `refs/heads/${branch}`, head.commit])
  await git(["--git-dir", gitDir, "symbolic-ref", "HEAD", `refs/heads/${branch}`])
}

export const sourceHeadOf = async (gitDir: string): Promise<string | undefined> => {
  const [head, sync] = await Promise.all([resolve(gitDir, "HEAD"), resolve(gitDir, SYNC_REF)])
  return head === undefined || head === sync ? undefined : head
}

export const syncHeadOf = (gitDir: string): Promise<string | undefined> => resolve(gitDir, SYNC_REF)

const resolve = async (gitDir: string, ref: string): Promise<string | undefined> => {
  const output = await git(["--git-dir", gitDir, "rev-parse", "--verify", "--quiet", ref]).catch(
    () => ""
  )
  return output.trim() === "" ? undefined : output.trim()
}

const markShallow = async (gitDir: string, commit: string): Promise<void> => {
  const path = join(gitDir, "shallow")
  const listed = (await readFile(path, "utf8").catch(() => ""))
    .split("\n")
    .filter((line) => line.length > 0)
  if (listed.includes(commit)) return
  await writeFile(path, `${[...listed, commit].join("\n")}\n`)
}

const validBranch = async (branch: string | undefined): Promise<string | undefined> => {
  if (branch === undefined) return undefined
  const checked = await git(["check-ref-format", "--branch", branch]).catch(() => undefined)
  const name = checked?.trim()
  return name === undefined || name === "" || `refs/heads/${name}` === SYNC_REF ? undefined : name
}

const dropStaleBranches = async (gitDir: string, keep: string | undefined): Promise<void> => {
  const listed = await git([
    "--git-dir",
    gitDir,
    "for-each-ref",
    "--format=%(refname)",
    "refs/heads/"
  ])
  const kept = new Set([SYNC_REF, ...(keep === undefined ? [] : [`refs/heads/${keep}`])])
  for (const ref of listed.split("\n").filter((line) => line.length > 0 && !kept.has(line))) {
    await git(["--git-dir", gitDir, "update-ref", "-d", ref])
  }
}
