import { createHash } from "node:crypto"
import { readFile, readdir, readlink } from "node:fs/promises"
import { join } from "node:path"

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
    for (const name of [...byName.keys()].toSorted()) {
      /* v8 ignore next */
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
    }
  }
  await walk(root, "")
  return hash.digest("hex")
}
