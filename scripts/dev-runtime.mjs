import { readFile, rm, writeFile } from "node:fs/promises"

export async function claimDevelopmentRunner(manifestPath, manifest) {
  const serializedManifest = `${JSON.stringify(manifest, null, 2)}\n`

  while (true) {
    try {
      await writeFile(manifestPath, serializedManifest, { flag: "wx" })
      return
    } catch (error) {
      if (error?.code !== "EEXIST") throw error
    }

    const existing = await readManifest(manifestPath)
    if (existing === undefined) continue
    if (processIsRunning(existing.pid)) {
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

function processIsRunning(processID) {
  if (!Number.isSafeInteger(processID) || processID <= 0) return false
  try {
    process.kill(processID, 0)
    return true
  } catch (error) {
    return error?.code === "EPERM"
  }
}
