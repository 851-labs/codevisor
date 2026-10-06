import { lstat, readFile } from "node:fs/promises"
import { basename, join } from "node:path"

import {
  assertSafeChild,
  copyDirectory,
  MANAGED_SKILL_MARKER,
  MANAGED_SKILL_MARKER_CONTENT,
  readSkillDocument,
  RESERVED_SKILL_NAMES,
  sanitizeName
} from "./skills-store.js"

export type ImportOutcome = "imported" | "conflict" | "reserved"

/// The directory name a skill folder imports under: its frontmatter name,
/// falling back to the folder name.
export const importedDirectoryName = async (source: string): Promise<string> => {
  const document = await readSkillDocument(source, basename(source))
  return sanitizeName(document.invalid ? basename(source) : document.name)
}

/// Copy one on-disk skill folder into the store, reporting the outcome
/// rather than throwing so batch imports can report per-skill results.
export const importDirectory = async (
  dir: string,
  source: string
): Promise<{ readonly directoryName: string; readonly outcome: ImportOutcome }> => {
  const directoryName = await importedDirectoryName(source)
  if (RESERVED_SKILL_NAMES.has(directoryName)) return { directoryName, outcome: "reserved" }
  const destination = assertSafeChild(dir, directoryName)
  if (await exists(destination)) return { directoryName, outcome: "conflict" }
  await copyDirectory(source, destination)
  return { directoryName, outcome: "imported" }
}

export const exists = async (path: string): Promise<boolean> => {
  try {
    await lstat(path)
    return true
  } catch {
    return false
  }
}

/// True when the folder carries the marker Codevisor put on skills it
/// installed itself.
export const isManagedSkillDir = async (dir: string): Promise<boolean> => {
  try {
    return (
      (await readFile(join(dir, MANAGED_SKILL_MARKER), "utf8")) === MANAGED_SKILL_MARKER_CONTENT
    )
  } catch {
    return false
  }
}
