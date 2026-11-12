import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { readdirSync } from "node:fs"
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

import { isMissing, pathExists } from "./files.ts"

const repoRootMarker = "repo-root"

export function devInstancesRoot(): string {
  return join(homedir(), ".codevisor-development", "instances")
}

export function instanceWorktreesRoot(
  repoRoot: string,
  instancesRoot = devInstancesRoot()
): string {
  const legacy = join(repoRoot, "tmp", "codevisor")
  if (holdsEntries(legacy)) return legacy
  return join(instancesRoot, instanceHash(repoRoot), "codevisor")
}

export async function claimInstanceRoot(
  repoRoot: string,
  worktreesRoot: string,
  instancesRoot = devInstancesRoot()
): Promise<void> {
  const instanceRoot = dirname(worktreesRoot)
  if (dirname(instanceRoot) !== instancesRoot) return

  await mkdir(instanceRoot, { recursive: true })
  await writeFile(join(instanceRoot, repoRootMarker), repoRoot)
}

export async function pruneOrphanInstanceRoots(
  instancesRoot = devInstancesRoot(),
  remove: (path: string) => void = removeInBackground
): Promise<ReadonlyArray<string>> {
  const orphans: Array<string> = []
  for (const name of await entriesOf(instancesRoot)) {
    const instanceRoot = join(instancesRoot, name)
    if (await isOrphan(instanceRoot)) orphans.push(instanceRoot)
  }
  for (const orphan of orphans) remove(orphan)
  return orphans
}

function instanceHash(repoRoot: string): string {
  return createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
}

function holdsEntries(directory: string): boolean {
  try {
    return readdirSync(directory).length > 0
  } catch {
    return false
  }
}

async function isOrphan(instanceRoot: string): Promise<boolean> {
  const repoRoot = await claimedRepoRoot(instanceRoot)
  if (repoRoot === undefined) return false
  return !(await pathExists(repoRoot))
}

async function claimedRepoRoot(instanceRoot: string): Promise<string | undefined> {
  try {
    return await readFile(join(instanceRoot, repoRootMarker), "utf8")
  } catch {
    return undefined
  }
}

async function entriesOf(directory: string): Promise<ReadonlyArray<string>> {
  try {
    return await readdir(directory)
  } catch (error) {
    if (isMissing(error)) return []
    throw error
  }
}

function removeInBackground(path: string): void {
  spawn("/bin/rm", ["-rf", "--", path], { detached: true, stdio: "ignore" }).unref()
}
