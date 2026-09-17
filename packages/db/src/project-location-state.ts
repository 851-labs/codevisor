import { existsSync, statSync } from "node:fs"
import { dirname, join, resolve } from "node:path"

import type Database from "better-sqlite3"

import { scratchWorkspacesRoot } from "./paths.js"

export const detectGitLocation = (folder: string): boolean => {
  try {
    if (!statSync(folder).isDirectory()) return false
  } catch {
    return false
  }
  if (dirname(folder) === scratchWorkspacesRoot()) return false
  let current = resolve(folder)
  while (true) {
    if (existsSync(join(current, ".git"))) return true
    const parent = dirname(current)
    if (current === parent) return false
    current = parent
  }
}

/** One-time metadata migration. Navigation reads never probe the filesystem. */
export const migrateProjectLocationState = (db: Database.Database): void => {
  const rows = db
    .prepare("select id, folder_path from project_locations where is_git_repository is null")
    .all() as Array<{ id: string; folder_path: string }>
  for (const row of rows)
    db.prepare("update project_locations set is_git_repository = ? where id = ?").run(
      Number(detectGitLocation(row.folder_path)),
      row.id
    )
}
