import { opendir, stat, rm } from "node:fs/promises"
import { join } from "node:path"

const scans = new Map<string, Promise<void>>()
let writes = 0

/** Derived files only. Originals are never in this directory. */
export const trimMediaPreviewCache = async (folder: string): Promise<void> => {
  if (writes++ % 64 !== 0) return
  const running = scans.get(folder)
  if (running !== undefined) return running
  const task = (async () => {
    let entries: Array<{ path: string; size: number; time: number }> = []
    let bytes = 0
    for await (const entry of await opendir(folder)) {
      if (!/^[a-f0-9]{64}\.png$/.test(entry.name)) continue
      const path = join(folder, entry.name)
      const info = await stat(path).catch(() => undefined)
      if (info === undefined) continue
      entries.push({ path, size: info.size, time: info.mtimeMs })
      bytes += info.size
      if (entries.length >= 4096 || bytes > 256 * 1024 * 1024) {
        entries.sort((a, b) => b.time - a.time)
        while (entries.length > 2048 || bytes > 192 * 1024 * 1024) {
          const removed = entries.pop()!
          bytes -= removed.size
          await rm(removed.path, { force: true })
        }
      }
    }
  })()
  scans.set(folder, task)
  try {
    await task
  } finally {
    scans.delete(folder)
  }
}
