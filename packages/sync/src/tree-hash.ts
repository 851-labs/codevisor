import { createHash } from "node:crypto"
import { readFile, readdir, readlink } from "node:fs/promises"
import { join } from "node:path"

/// A deterministic content hash for a directory tree — the blob identity
/// the config plane replicates big payloads (skill directories) by. Two
/// trees with identical relative paths, file bytes, and symlink targets
/// hash identically on every machine, regardless of timestamps, archive
/// encoding, or traversal order.
export const treeHash = async (
  root: string,
  options?: { readonly exclude?: ReadonlySet<string> }
): Promise<string> => {
  const exclude = options?.exclude ?? new Set()
  const hash = createHash("sha256")
  const walk = async (directory: string, prefix: string): Promise<void> => {
    const entries = (await readdir(directory, { withFileTypes: true })).filter(
      (entry) => !exclude.has(entry.name)
    )
    const byName = new Map(entries.map((entry) => [entry.name, entry]))
    // Default string sort is UTF-16 code-unit order — deterministic on every
    // machine, unlike localeCompare, whose collation varies by locale and
    // would make the "identity" hash platform-dependent.
    for (const name of [...byName.keys()].sort()) {
      /* v8 ignore next -- names derive from entries; the map always hits. */
      const entry = byName.get(name)!
      const relative = prefix === "" ? name : `${prefix}/${name}`
      const absolute = join(directory, name)
      if (entry.isDirectory()) {
        hash.update(`dir:${relative}\n`)
        await walk(absolute, relative)
      } else if (entry.isSymbolicLink()) {
        const target = await readlink(absolute)
        hash.update(`link:${relative}:${target}\n`)
      } else if (entry.isFile()) {
        const contents = await readFile(absolute)
        hash.update(`file:${relative}:${contents.byteLength}\n`)
        hash.update(contents)
      }
      // Sockets/devices/etc. are ignored: they cannot be replicated anyway.
    }
  }
  await walk(root, "")
  return hash.digest("hex")
}
