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

  for (const dir of harnessDirs.values()) {
    const paths = (await readEntries(dir)).map((name) => join(dir, name))
    for (const path of paths) {
      const owned = await isCodevisorEntry(path).catch(
        /* v8 ignore next */
        () => false
      )
      if (!owned) continue
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
      /* v8 ignore next */
    }
  }
  await mkdir(environment.storeDir, { recursive: true })
  await writeFile(marker, `${JSON.stringify({ imported })}\n`, "utf8")
  return imported
}

export const migrateLegacySkills = async (
  environment: LegacySkillsEnvironment & { readonly storeDir: string }
): Promise<ReadonlyArray<string>> => {
  await removeLegacyManagedSkills(environment)
  return importLegacyUserSkills(environment)
}
