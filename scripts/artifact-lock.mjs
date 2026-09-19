// Cross-process mutual exclusion for the shared artifact roots under
// ~/.codevisor-development/artifacts.
//
// Several worktrees may provision the same artifact at the same time. The
// first to create the lock file does the work; the others wait, then find
// the finished artifact and skip. A lock whose owning process is gone is
// stale and is taken over — the same convention package managers use for
// their shared caches.
import { mkdir, open, readFile, rm } from "node:fs/promises"
import { dirname } from "node:path"
import { setTimeout as sleep } from "node:timers/promises"

const processIsAlive = (pid) => {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    // EPERM: the process exists but belongs to another user.
    return error.code === "EPERM"
  }
}

/// Runs `action` while holding `lockPath`. Returns the action's result and
/// always releases the lock, including when the action throws.
export async function withArtifactLock(
  lockPath,
  action,
  { retryDelay = () => sleep(250), isProcessAlive = processIsAlive, pid = process.pid } = {}
) {
  await mkdir(dirname(lockPath), { recursive: true })
  for (;;) {
    let handle
    try {
      handle = await open(lockPath, "wx")
    } catch (error) {
      if (error.code !== "EEXIST") throw error
      const owner = Number.parseInt(await readFile(lockPath, "utf8").catch(() => ""), 10)
      if (Number.isInteger(owner) && !isProcessAlive(owner)) {
        // Stale. Two waiters may both remove it; exactly one wins the next
        // exclusive create and the other loops back to waiting.
        await rm(lockPath, { force: true })
        continue
      }
      await retryDelay()
      continue
    }
    try {
      await handle.writeFile(String(pid))
    } finally {
      await handle.close()
    }
    break
  }
  try {
    return await action()
  } finally {
    await rm(lockPath, { force: true })
  }
}
