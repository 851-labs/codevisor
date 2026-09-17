import { randomUUID } from "node:crypto"
import { link, readFile, rm, writeFile } from "node:fs/promises"

import { processIdentity } from "../packages/processes/src/index.mjs"

/// The claim one development runner publishes while it owns a worktree.
export interface DevelopmentRunnerManifest {
  kind: string
  pid: number
  repoRoot: string
  startedAt?: string | undefined
  ownerPid?: number | undefined
  ownerStartedAt?: string | undefined
}

/// A manifest as read back from disk: it was written by another process —
/// possibly an older runner, possibly mid-write — so no field is guaranteed.
export type StoredDevelopmentRunnerManifest = Partial<DevelopmentRunnerManifest>

export async function claimDevelopmentRunner(
  manifestPath: string,
  manifest: DevelopmentRunnerManifest
): Promise<void> {
  const serializedManifest = `${JSON.stringify(manifest, null, 2)}\n`

  while (true) {
    try {
      const temporary = `${manifestPath}.${randomUUID()}.tmp`
      try {
        await writeFile(temporary, serializedManifest)
        // Publish a complete manifest atomically; contenders never mistake
        // a partially written live claim for a crashed owner.
        await link(temporary, manifestPath)
      } finally {
        await rm(temporary, { force: true })
      }
      return
    } catch (error) {
      if ((error as NodeJS.ErrnoException | undefined)?.code !== "EEXIST") throw error
    }

    const existing = await readManifest(manifestPath)
    if (existing === undefined) continue
    // A corrupt or legacy manifest can carry neither pid. Passing the absent
    // value through is deliberate — the lookup then matches no live process,
    // which is what lets the loop reclaim the stale manifest — but
    // processIdentity is typed for a pid, so the cast is unavoidable here.
    const identity = await processIdentity((existing.ownerPid ?? existing.pid) as number)
    if (identity && (!existing.ownerStartedAt || existing.ownerStartedAt === identity.startedAt)) {
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
  manifest: DevelopmentRunnerManifest
): Promise<void> {
  const existing = await readManifest(manifestPath)
  if (existing?.pid !== manifest.pid || existing.repoRoot !== manifest.repoRoot) return
  if (manifest.startedAt !== undefined && existing.startedAt !== manifest.startedAt) return
  await rm(manifestPath, { force: true })
}

async function readManifest(
  manifestPath: string
): Promise<StoredDevelopmentRunnerManifest | undefined> {
  try {
    return JSON.parse(await readFile(manifestPath, "utf8"))
  } catch (error) {
    if ((error as NodeJS.ErrnoException | undefined)?.code === "ENOENT") return undefined
    if (error instanceof SyntaxError) return {}
    throw error
  }
}
