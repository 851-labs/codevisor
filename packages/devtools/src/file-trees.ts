import { lstat, readdir, readlink } from "node:fs/promises"
import { join, relative } from "node:path"

export type TreeEntry =
  | { readonly type: "directory" }
  | { readonly type: "symlink"; readonly target: string }
  | {
      readonly type: "file"
      readonly size: number
      readonly mode: number
      readonly atime: Date
      readonly mtime: Date
    }

export async function listTree(root: string): Promise<Map<string, TreeEntry>> {
  const entries = new Map<string, TreeEntry>()
  const visit = async (directory: string): Promise<void> => {
    for (const child of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, child.name)
      const key = relative(root, path)
      if (child.isDirectory()) {
        entries.set(key, { type: "directory" })
        await visit(path)
      } else if (child.isSymbolicLink()) {
        entries.set(key, { type: "symlink", target: await readlink(path) })
      } else if (child.isFile()) {
        const info = await lstat(path)
        entries.set(key, {
          type: "file",
          size: info.size,
          mode: info.mode & 0o7777,
          atime: info.atime,
          mtime: info.mtime
        })
      }
    }
  }
  await visit(root)
  return entries
}

export function describeDifference(
  local: ReadonlyMap<string, TreeEntry>,
  reference: ReadonlyMap<string, TreeEntry>
): string | undefined {
  if (local.size !== reference.size) return `${local.size} entries, store has ${reference.size}`

  for (const [path, file] of local) {
    const other = reference.get(path)
    if (other === undefined) return `${path} missing from store`
    if (!sameEntry(file, other)) return `${path} changed`
  }
  return undefined
}

function sameEntry(a: TreeEntry, b: TreeEntry): boolean {
  if (a.type !== b.type) return false
  if (a.type === "symlink" && b.type === "symlink") return a.target === b.target
  if (a.type === "file" && b.type === "file") return a.size === b.size && a.mode === b.mode

  return true
}
