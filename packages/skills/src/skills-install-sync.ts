import type { SkillsScan } from "@codevisor/api"
import { lstat, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { resolveNativeConfigPath } from "./native-paths.js"
import { assertSafeChild, safeRemove, type SkillsInstallContext } from "./skills-install-context.js"
import type { ManagedSkillSpec } from "./skills-manager.js"
import {
  copyDirectory,
  hasSkillFile,
  isDirectory,
  MANAGED_SKILL_MARKER,
  MANAGED_SKILL_MARKER_CONTENT
} from "./skills-store.js"

/// Bulk synchronization: re-linking global skills into every harness, and
/// materializing the app-managed skills shipped with Codevisor.
export const makeSkillsSyncOperations = (context: SkillsInstallContext) => {
  const {
    canonicalDir,
    canonicalSkillPath,
    config,
    env,
    home,
    installEverywhere,
    isManagedSkill,
    list,
    listCanonical
  } = context

  const sync = async (request?: {
    readonly directoryNames?: ReadonlyArray<string> | undefined
  }): Promise<SkillsScan> => {
    const requested = request?.directoryNames
    let names: ReadonlyArray<string>
    if (requested === undefined || requested.length === 0) {
      names = (await listCanonical()).map((skill) => skill.directoryName)
    } else {
      // Validate every requested name before touching anything.
      for (const name of requested) await canonicalSkillPath(name)
      names = requested
    }
    await installEverywhere(names)
    return list()
  }

  const syncManaged = async (skills: ReadonlyArray<ManagedSkillSpec>): Promise<void> => {
    for (const skill of skills) {
      const destination = assertSafeChild(canonicalDir, skill.directoryName)

      let existing
      try {
        existing = await lstat(destination)
      } catch {
        existing = undefined
      }

      if (existing !== undefined && !(await isManagedSkill(destination))) {
        // A user owns this name. Never replace or hide it; the managed skill
        // remains unavailable until the collision is resolved.
        continue
      }

      // Remove app-owned copy-mode installs before replacing the canonical
      // source. Symlinks can stay when enabled because they resolve to the
      // freshly written canonical directory; disabled skills remove both.
      for (const definition of config.agents.catalog) {
        const spec = definition.skills
        if (
          spec === undefined ||
          spec.readsCanonical === true ||
          spec.alsoReadsCanonical === true
        ) {
          continue
        }
        const skillsDir = resolveNativeConfigPath(spec.globalDir, { env, home })
        const installed = join(skillsDir, skill.directoryName)
        let installedStats
        try {
          installedStats = await lstat(installed)
        } catch {
          installedStats = undefined
        }
        if (installedStats === undefined) continue
        /* v8 ignore next -- copy-mode harnesses exercise the non-symlink recovery branch. */
        if (installedStats.isSymbolicLink()) {
          if (!skill.enabled) await rm(installed, { force: true })
          continue
        }
        /* v8 ignore next -- recovery for a stale managed copy-mode install. */
        if (await isManagedSkill(installed)) await safeRemove(installed)
      }

      if (existing !== undefined) await safeRemove(destination)
      if (!skill.enabled) continue
      /* v8 ignore next -- packaged managed sources are validated during release assembly. */
      if (!(await isDirectory(skill.sourcePath)) || !(await hasSkillFile(skill.sourcePath))) {
        throw new Error(`Managed skill source is invalid: ${skill.sourcePath}`)
      }
      await copyDirectory(skill.sourcePath, destination)
      await writeFile(join(destination, MANAGED_SKILL_MARKER), MANAGED_SKILL_MARKER_CONTENT, "utf8")
    }

    const enabled = skills.filter((skill) => skill.enabled).map((skill) => skill.directoryName)
    await installEverywhere(enabled)
  }

  return { sync, syncManaged }
}
