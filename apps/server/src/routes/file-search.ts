import { opendir, stat } from "node:fs/promises"
import { join, relative } from "node:path"

export interface FileSearchEntry {
  name: string
  path: string
  isDirectory: boolean
  isSymbolicLink: boolean
}

// Search on the machine that owns the files, without downloading every folder
// to the phone. Never follow directory symlinks into cycles or outside the root.
export async function searchFileEntries(
  root: string,
  query: string,
  options: { signal?: AbortSignal; maxResults?: number; maxEntries?: number } = {}
) {
  const needle = query.trim().toLowerCase()
  const entries: FileSearchEntry[] = []
  let truncated = false
  let skippedDirectories = 0
  if (!needle) return { path: root, entries, truncated, skippedDirectories }
  const pending = [root]
  const maxResults = options.maxResults ?? 500
  const maxEntries = options.maxEntries ?? 100_000
  let visited = 0
  search: while (pending.length > 0) {
    options.signal?.throwIfAborted()
    const directory = pending.shift()!
    try {
      const handle = await opendir(directory)
      for await (const entry of handle) {
        options.signal?.throwIfAborted()
        if (++visited > maxEntries) {
          truncated = true
          break search
        }
        const path = join(directory, entry.name)
        if (entry.isDirectory()) {
          pending.push(path)
          continue
        }
        if (!relative(root, path).toLowerCase().includes(needle)) continue
        let isFile = entry.isFile()
        if (entry.isSymbolicLink()) {
          try {
            isFile = (await stat(path)).isFile()
          } catch {
            continue
          }
        }
        if (!isFile) continue
        if (entries.length === maxResults) {
          truncated = true
          break search
        }
        entries.push({
          name: entry.name,
          path,
          isDirectory: false,
          isSymbolicLink: entry.isSymbolicLink()
        })
      }
    } catch (error) {
      options.signal?.throwIfAborted()
      if (directory === root) throw error
      skippedDirectories++
    }
  }
  entries.sort((a, b) => a.path.localeCompare(b.path, "en", { numeric: true }))
  return { path: root, entries, truncated, skippedDirectories }
}
