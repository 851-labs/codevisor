import type { SkillsScan } from "@codevisor/api"
import { lstat, mkdir, readdir, readlink, rm } from "node:fs/promises"
import { join, resolve } from "node:path"
import { resolveNativeConfigPath } from "./native-paths.js"
import {
  assertSafeChild,
  definitionName,
  safeRemove,
  type SkillsInstallContext
} from "./skills-install-context.js"
import {
  copyDirectory,
  hasSkillFile,
  isPathSafe,
  resolveExisting,
  resolveSymlinkTarget,
  sanitizeName,
  skillContentHash,
  SkillsError
} from "./skills-store.js"

/// Per-harness install state changes: installing/uninstalling a global
/// skill in one harness, promoting a harness copy to global, and deleting
/// a global skill along with every link that pointed at it.
export const makeSkillsHarnessOperations = (context: SkillsInstallContext) => {
  const {
    canonicalDir,
    canonicalSkillPath,
    config,
    createSkillLink,
    env,
    harnessSkillsDir,
    home,
    installIntoDir,
    list,
    renameFn
  } = context

  const remove = async (directoryName: string): Promise<SkillsScan> => {
    const path = assertSafeChild(canonicalDir, directoryName)
    try {
      await lstat(path)
    } catch {
      throw new SkillsError(`No global skill named ${directoryName}`, "notFound")
    }
    // Inside the canonical store and lstat-verified: recursive removal is
    // allowed (links still remove as links via safeRemove).
    await safeRemove(path)

    // Sweep the now-dangling links out of every harness skills directory.
    const removedTargets = [resolve(path), join(await resolveExisting(canonicalDir), directoryName)]
    for (const definition of config.agents.catalog) {
      const spec = definition.skills
      if (spec === undefined || spec.readsCanonical === true) continue
      const skillsDir = resolveNativeConfigPath(spec.globalDir, { env, home })
      let entries
      try {
        entries = await readdir(skillsDir, { withFileTypes: true })
      } catch {
        continue
      }
      for (const entry of entries) {
        if (!entry.isSymbolicLink()) continue
        const linkPath = join(skillsDir, entry.name)
        try {
          const target = resolveSymlinkTarget(linkPath, await readlink(linkPath))
          if (removedTargets.some((removed) => isPathSafe(removed, target))) {
            await rm(linkPath, { force: true })
          }
        } catch {
          /* v8 ignore next -- readlink on an lstat-verified link only fails on concurrent removal. */
          // Unreadable link: leave it for the broken-link repair flow.
        }
      }
    }
    return list()
  }

  const setInstalled = async (
    directoryName: string,
    harnessId: string,
    installed: boolean
  ): Promise<SkillsScan> => {
    const { alsoReadsCanonical, dir: skillsDir, readsCanonical } = harnessSkillsDir(harnessId)
    const dirIsCanonical =
      readsCanonical || (await resolveExisting(skillsDir)) === (await resolveExisting(canonicalDir))
    // Canonical-reading harnesses see every global skill natively; there is
    // nothing to install (ambient readers may still have redundant links
    // worth removing, so only uninstalls fall through for them).
    if (dirIsCanonical || (installed && alsoReadsCanonical)) {
      await canonicalSkillPath(directoryName)
      return list()
    }
    const linkPath = assertSafeChild(skillsDir, directoryName)

    if (installed) {
      await installIntoDir(directoryName, skillsDir, definitionName(config, harnessId))
      return list()
    }

    let stats
    try {
      stats = await lstat(linkPath)
    } catch {
      return list()
    }
    if (stats.isSymbolicLink()) {
      // lstat above proved this is a link, so readlink cannot miss.
      const target = resolveSymlinkTarget(linkPath, await readlink(linkPath))
      const canonicalReal = await resolveExisting(canonicalDir)
      if (!isPathSafe(canonicalDir, target) && !isPathSafe(canonicalReal, target)) {
        throw new SkillsError(
          `${directoryName} in ${definitionName(config, harnessId)} links outside the canonical store — remove it manually`,
          "conflict"
        )
      }
      await rm(linkPath, { force: true })
      return list()
    }
    if (stats.isDirectory()) {
      // Copy-mode install (or a user copy): only remove what provably
      // matches the canonical content.
      const canonicalPath = await canonicalSkillPath(directoryName)
      if ((await skillContentHash(linkPath)) !== (await skillContentHash(canonicalPath))) {
        throw new SkillsError(
          `${directoryName} in ${definitionName(config, harnessId)} was modified — remove it manually`,
          "conflict"
        )
      }
      await safeRemove(linkPath)
      return list()
    }
    await rm(linkPath, { force: true })
    return list()
  }

  const makeGlobal = async (harnessId: string, directoryName: string): Promise<SkillsScan> => {
    const { alsoReadsCanonical, dir: skillsDir, readsCanonical } = harnessSkillsDir(harnessId)
    // Guard BOTH the declared canonical readers and harness dirs the user
    // symlinked onto the canonical store: "promoting" through such a dir
    // would recursively delete the canonical skill via the symlinked parent.
    if (
      readsCanonical ||
      (await resolveExisting(skillsDir)) === (await resolveExisting(canonicalDir))
    ) {
      throw new SkillsError(
        `${definitionName(config, harnessId)} reads the canonical store directly`,
        "invalid"
      )
    }
    const sourcePath = assertSafeChild(skillsDir, directoryName)
    let stats
    try {
      stats = await lstat(sourcePath)
    } catch {
      throw new SkillsError(`No skill at ${sourcePath}`, "notFound")
    }
    if (stats.isSymbolicLink()) {
      throw new SkillsError(`${directoryName} is already a link, not a copy`, "invalid")
    }
    if (!stats.isDirectory() || !(await hasSkillFile(sourcePath))) {
      throw new SkillsError(`${sourcePath} is not a skill directory`, "invalid")
    }

    const destinationName = sanitizeName(directoryName)
    const destination = assertSafeChild(canonicalDir, destinationName)

    let destinationExists = false
    try {
      await lstat(destination)
      destinationExists = true
    } catch {
      destinationExists = false
    }

    if (destinationExists) {
      // Same content: replace the harness copy with a link to the existing
      // canonical skill. Different content: refuse — renaming is a user call.
      if ((await skillContentHash(sourcePath)) !== (await skillContentHash(destination))) {
        throw new SkillsError(
          `A different skill named ${destinationName} already exists globally — rename one of them first`,
          "conflict"
        )
      }
      await safeRemove(sourcePath)
      // Ambient canonical readers see the skill without a link back.
      if (!alsoReadsCanonical) {
        const result = await createSkillLink(destination, sourcePath)
        if (result === "failed") await copyDirectory(destination, sourcePath)
      }
      return list()
    }

    await mkdir(canonicalDir, { recursive: true })
    try {
      await renameFn(sourcePath, destination)
    } catch (cause) {
      if ((cause as NodeJS.ErrnoException).code !== "EXDEV") throw cause
      // Cross-device move: copy, verify byte-for-byte, then remove source.
      await copyDirectory(sourcePath, destination)
      /* v8 ignore next 4 -- failsafe: copyDirectory is deterministic, so a mismatch means concurrent modification. */
      if ((await skillContentHash(destination)) !== (await skillContentHash(sourcePath))) {
        await rm(destination, { force: true, recursive: true })
        throw new SkillsError(`Copy verification failed moving ${directoryName}`, "conflict")
      }
      await safeRemove(sourcePath)
    }
    if (!alsoReadsCanonical) {
      const result = await createSkillLink(destination, sourcePath)
      if (result === "failed") await copyDirectory(destination, sourcePath)
    }
    return list()
  }

  return { makeGlobal, remove, setInstalled }
}
