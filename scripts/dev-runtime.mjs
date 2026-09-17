import { randomUUID } from "node:crypto"
import { link, readFile, rm, writeFile } from "node:fs/promises"

import { processIdentity } from "../packages/processes/src/index.mjs"

export async function claimDevelopmentRunner(manifestPath, manifest) {
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
      if (error?.code !== "EEXIST") throw error
    }

    const existing = await readManifest(manifestPath)
    if (existing === undefined) continue
    const identity = await processIdentity(existing.ownerPid ?? existing.pid)
    if (identity && (!existing.ownerStartedAt || existing.ownerStartedAt === identity.startedAt)) {
      const owner = existing.repoRoot ?? "an unknown worktree"
      throw new Error(
        `A Codevisor development runner is already active for ${owner} (PID ${existing.pid}).`
      )
    }

    await rm(manifestPath, { force: true })
  }
}

export async function releaseDevelopmentRunner(manifestPath, manifest) {
  const existing = await readManifest(manifestPath)
  if (existing?.pid !== manifest.pid || existing.repoRoot !== manifest.repoRoot) return
  if (manifest.startedAt !== undefined && existing.startedAt !== manifest.startedAt) return
  await rm(manifestPath, { force: true })
}

async function readManifest(manifestPath) {
  try {
    return JSON.parse(await readFile(manifestPath, "utf8"))
  } catch (error) {
    if (error?.code === "ENOENT") return undefined
    if (error instanceof SyntaxError) return {}
    throw error
  }
}
