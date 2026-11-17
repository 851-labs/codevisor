import { createHash } from "node:crypto"
import { readdirSync } from "node:fs"
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

import { isMissing, pathExists } from "./files.ts"

export interface ClaimedInstance {
  readonly hash: string
  readonly root: string
  readonly repoRoot: string
}

type Environment = Readonly<Record<string, string | undefined>>

const repoRootMarker = "repo-root"
const checkoutMarkers = [".git", "package.json"]

export function devInstancesRoot(environment: Environment = process.env): string {
  return (
    environment.CODEVISOR_DEV_INSTANCES_ROOT ??
    join(homedir(), ".codevisor-development", "instances")
  )
}

export function instanceHash(repoRoot: string): string {
  return createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
}

export function instanceWorktreesRoot(
  repoRoot: string,
  instancesRoot = devInstancesRoot()
): string {
  const legacy = join(repoRoot, "tmp", "codevisor")
  if (holdsEntries(legacy)) return legacy
  return join(instancesRoot, instanceHash(repoRoot), "codevisor")
}

export async function claimInstance(
  repoRoot: string,
  instancesRoot = devInstancesRoot()
): Promise<void> {
  const instanceRoot = join(instancesRoot, instanceHash(repoRoot))
  await mkdir(instanceRoot, { recursive: true })
  await writeFile(join(instanceRoot, repoRootMarker), repoRoot)
}

export async function claimedInstances(
  instancesRoot = devInstancesRoot()
): Promise<ReadonlyArray<ClaimedInstance>> {
  const claimed: Array<ClaimedInstance> = []
  for (const hash of await entriesOf(instancesRoot)) {
    const root = join(instancesRoot, hash)
    const repoRoot = await claimedRepoRoot(root)
    if (repoRoot !== undefined && instanceHash(repoRoot) === hash)
      claimed.push({ hash, root, repoRoot })
  }
  return claimed
}

export async function worktreeIsGone(repoRoot: string): Promise<boolean> {
  for (const marker of checkoutMarkers) {
    if (await pathExists(join(repoRoot, marker))) return false
  }
  return true
}

function holdsEntries(directory: string): boolean {
  try {
    return readdirSync(directory).length > 0
  } catch {
    return false
  }
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
