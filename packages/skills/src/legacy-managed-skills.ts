import { lstat, mkdir, readdir, readlink, realpath, rm, writeFile } from "node:fs/promises"
import { join, resolve } from "node:path"

import type { AgentRuntimeService } from "@codevisor/agent-runtime"

import { resolveNativeConfigPath } from "./native-paths.js"
import { exists, importDirectory, isManagedSkillDir } from "./skill-import.js"
import {
  CANONICAL_SKILLS_DIR,
  hasSkillFile,
  isDirectory,
  isPathSafe,
  resolveSymlinkTarget
} from "./skills-store.js"

/// Skills older Codevisor versions installed into ~/.agents/skills and linked
/// into every harness. They are served by the gateway's `skills` tool now.
export const LEGACY_MANAGED_SKILLS: ReadonlyArray<string> = [
  "attaching-files",
  "browser-use",
  "codevisor",
  "codevisor-agents",
  "codevisor-clients",
  "codevisor-machines",
  "computer-use",
  "create-codevisor-plugin"
]

/// Written into the store once the user's ~/.agents/skills have been
/// imported, so the import runs exactly once per machine.
export const LEGACY_IMPORT_MARKER = ".imported-from-agents-skills-v1"

export interface LegacySkillsEnvironment {
  readonly agents: AgentRuntimeService
  readonly homedir: string
  readonly env: Readonly<Record<string, string | undefined>>
}

const canonicalDir = (environment: LegacySkillsEnvironment): string =>
  resolveNativeConfigPath(CANONICAL_SKILLS_DIR, {
    env: environment.env,
    home: environment.homedir
  })

const readEntries = async (dir: string): Promise<ReadonlyArray<string>> => {
  try {
    return await readdir(dir)
  } catch {
    return []
  }
}

/// Remove the skills Codevisor installed: their folders in ~/.agents/skills
/// (recognized by the exact managed marker), the links pointing at them from
/// harness skills folders, and marked copies made where links failed.
/// Anything else, including a user's same-named skill or link, stays. Safe to
/// run on every launch (a failed pass is simply retried next launch); returns
/// the removed paths.
export const removeLegacyManagedSkills = async (
  environment: LegacySkillsEnvironment
): Promise<ReadonlyArray<string>> => {
  const canonical = canonicalDir(environment)
  const realCanonical = await realpath(canonical).catch(() => resolve(canonical))
  const managed: Array<string> = []
  for (const name of await readEntries(canonical)) {
    const path = join(canonical, name)
    const stats = await lstat(path)
    if (stats.isDirectory() && (await isManagedSkillDir(path))) managed.push(name)
  }
  const managedTargets = managed.flatMap((name) => [
    join(canonical, name),
    join(realCanonical, name)
  ])
  // A link left dangling by an interrupted earlier run points at a managed
  // name in the canonical folder that no longer exists.
  const formerTargets = new Set(
    LEGACY_MANAGED_SKILLS.flatMap((name) => [join(canonical, name), join(realCanonical, name)])
  )

  const removed: Array<string> = []
  const harnessDirs = new Map<string, string>()
  for (const definition of environment.agents.catalog) {
    if (definition.skills === undefined) continue
    const dir = resolveNativeConfigPath(definition.skills.globalDir, {
      env: environment.env,
      home: environment.homedir
    })
    const real = await realpath(dir).catch(() => undefined)
    if (real === undefined || real === realCanonical || harnessDirs.has(real)) continue
    harnessDirs.set(real, dir)
  }

  /// A link is Codevisor's when it points into a managed skill, or dangles at
  /// a managed name an interrupted earlier cleanup already removed.
  const isCodevisorLink = async (path: string): Promise<boolean> => {
    const target = resolveSymlinkTarget(path, await readlink(path))
    if (managedTargets.some((managedPath) => isPathSafe(managedPath, target))) return true
    return formerTargets.has(target) && !(await exists(target))
  }

  const isCodevisorEntry = async (path: string): Promise<boolean> => {
    const stats = await lstat(path)
    if (stats.isSymbolicLink()) return isCodevisorLink(path)
    return stats.isDirectory() && (await isManagedSkillDir(path))
  }

  // Links first, so an interruption never strands links to removed folders.
  for (const dir of harnessDirs.values()) {
    const paths = (await readEntries(dir)).map((name) => join(dir, name))
    for (const path of paths) {
      // Another Codevisor build sharing this home can add or remove entries
      // mid-scan; an entry that vanishes is simply not ours to remove.
      const owned = await isCodevisorEntry(path).catch(
        /* v8 ignore next -- needs a concurrent writer racing this scan */
        () => false
      )
      if (!owned) continue
      // rm never follows links, so this removes a link itself or a marked copy.
      await rm(path, { force: true, recursive: true })
      removed.push(path)
    }
  }

  for (const name of managed) {
    const path = join(canonical, name)
    await rm(path, { force: true, recursive: true })
    removed.push(path)
  }
  return removed
}

/// Copy the user's own skills from ~/.agents/skills into Codevisor's store,
/// once. The originals stay where they are for harnesses that read them
/// natively. Returns the imported directory names.
export const importLegacyUserSkills = async (
  environment: LegacySkillsEnvironment & { readonly storeDir: string }
): Promise<ReadonlyArray<string>> => {
  const marker = join(environment.storeDir, LEGACY_IMPORT_MARKER)
  if (await exists(marker)) return []
  const canonical = canonicalDir(environment)
  const imported: Array<string> = []
  for (const name of await readEntries(canonical)) {
    const path = join(canonical, name)
    if (name.startsWith(".") || !(await isDirectory(path)) || !(await hasSkillFile(path))) continue
    if (await isManagedSkillDir(path)) continue
    try {
      const { directoryName, outcome } = await importDirectory(environment.storeDir, path)
      if (outcome === "imported") imported.push(directoryName)
    } catch {
      /* v8 ignore next -- copy failures (permissions, I/O) need an environment tests can't fake. */
      // A skill that can't be copied is skipped; the user can import it later.
    }
  }
  await mkdir(environment.storeDir, { recursive: true })
  await writeFile(marker, `${JSON.stringify({ imported })}\n`, "utf8")
  return imported
}

/// The whole upgrade: remove what older builds installed, then (once) import
/// the user's own skills. Returns the imported directory names.
export const migrateLegacySkills = async (
  environment: LegacySkillsEnvironment & { readonly storeDir: string }
): Promise<ReadonlyArray<string>> => {
  await removeLegacyManagedSkills(environment)
  return importLegacyUserSkills(environment)
}
