import { randomUUID } from "node:crypto"
import { link, readFile, rm, writeFile } from "node:fs/promises"

import { isMissing } from "./files.ts"

export interface RunnerManifest {
  readonly pid?: number
  readonly ownerPid?: number
  readonly ownerStartedAt?: string
  readonly startedAt?: string
  readonly repoRoot?: string
  readonly [key: string]: unknown
}

export type ProcessIdentityLookup = (
  pid: number
) => Promise<{ readonly startedAt?: string } | undefined | null>

export async function claimDevelopmentRunner(
  manifestPath: string,
  manifest: RunnerManifest,
  processIdentity: ProcessIdentityLookup
): Promise<void> {
  const serialized = `${JSON.stringify(manifest, null, 2)}\n`
  for (;;) {
    if (await createExclusively(manifestPath, serialized)) return

    const existing = await readManifest(manifestPath)
    if (existing === undefined) continue
    if (await ownerIsAlive(existing, processIdentity)) {
      const owner = existing.repoRoot ?? "an unknown worktree"
      throw new Error(
        `A Codevisor development runner is already active for ${owner} (PID ${existing.pid}).`
      )
    }

    await rm(manifestPath, { force: true })
  }
}

export async function releaseDevelopmentRunner(
  manifestPath: string,
  manifest: RunnerManifest
): Promise<void> {
  const existing = await readManifest(manifestPath)
  if (existing === undefined) return
  if (existing.pid !== manifest.pid || existing.repoRoot !== manifest.repoRoot) return
  if (manifest.startedAt !== undefined && existing.startedAt !== manifest.startedAt) return

  await rm(manifestPath, { force: true })
}

async function createExclusively(path: string, contents: string): Promise<boolean> {
  const temporary = `${path}.${randomUUID()}.tmp`
  try {
    await writeFile(temporary, contents)
    await link(temporary, path)
    return true
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "EEXIST") return false
    throw error
  } finally {
    await rm(temporary, { force: true })
  }
}

async function ownerIsAlive(
  manifest: RunnerManifest,
  processIdentity: ProcessIdentityLookup
): Promise<boolean> {
  const pid = manifest.ownerPid ?? manifest.pid
  if (pid === undefined) return false

  const identity = await processIdentity(pid)
  if (!identity) return false

  return !manifest.ownerStartedAt || manifest.ownerStartedAt === identity.startedAt
}

async function readManifest(path: string): Promise<RunnerManifest | undefined> {
  try {
    return JSON.parse(await readFile(path, "utf8"))
  } catch (error) {
    if (isMissing(error)) return undefined
    if (error instanceof SyntaxError) return {}
    throw error
  }
}
