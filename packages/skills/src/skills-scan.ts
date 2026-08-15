import type {
  GlobalSkill,
  HarnessSkill,
  SkillHarnessInstall,
  SkillInstallState,
  SkillsHarnessGroup,
  SkillsScan
} from "@codevisor/api"
import { readdir, readFile, realpath } from "node:fs/promises"
import { basename, join } from "node:path"
import { resolveNativeConfigPath } from "./native-paths.js"
import type { SkillsManagerConfig } from "./skills-manager.js"
import {
  hasSkillFile,
  isDirectory,
  isPathSafe,
  MANAGED_SKILL_MARKER,
  MANAGED_SKILL_MARKER_CONTENT,
  readSkillDocument,
  resolveExisting,
  skillContentHash,
  type CanonicalSkill,
  type HarnessEntry,
  type SkillDocument
} from "./skills-store.js"

export interface SkillsScannerDeps {
  readonly canonicalDir: string
  readonly config: SkillsManagerConfig
  readonly env: Readonly<Record<string, string | undefined>>
  readonly home: string
}

export const makeSkillsScanner = (deps: SkillsScannerDeps) => {
  const { canonicalDir, config, env, home } = deps

  const isManagedSkill = async (path: string): Promise<boolean> => {
    try {
      return (
        (await readFile(join(path, MANAGED_SKILL_MARKER), "utf8")) === MANAGED_SKILL_MARKER_CONTENT
      )
    } catch {
      return false
    }
  }

  const listCanonical = async (): Promise<ReadonlyArray<CanonicalSkill>> => {
    let entries
    try {
      entries = await readdir(canonicalDir, { withFileTypes: true })
    } catch {
      return []
    }
    const skills: Array<CanonicalSkill> = []
    for (const entry of entries) {
      const path = join(canonicalDir, entry.name)
      if (!entry.isDirectory() && !(entry.isSymbolicLink() && (await isDirectory(path)))) {
        continue
      }
      if (!(await hasSkillFile(path))) continue
      if (await isManagedSkill(path)) continue
      skills.push({
        directoryName: entry.name,
        document: await readSkillDocument(path, entry.name),
        hash: await skillContentHash(path),
        path
      })
    }
    return skills.sort((a, b) => a.directoryName.localeCompare(b.directoryName))
  }

  /// Classify every entry in one harness skills directory. Never throws:
  /// unreadable dirs read as empty, broken links classify as `broken`.
  const listHarnessEntries = async (
    skillsDir: string,
    canonicalReal: string
  ): Promise<ReadonlyArray<HarnessEntry>> => {
    let entries
    try {
      entries = await readdir(skillsDir, { withFileTypes: true })
    } catch {
      return []
    }
    const results: Array<HarnessEntry> = []
    for (const entry of entries) {
      const path = join(skillsDir, entry.name)
      if (await isManagedSkill(path)) continue
      if (entry.isSymbolicLink()) {
        let target: string
        try {
          target = await realpath(path)
        } catch {
          // Dangling or circular (ELOOP) link — repairable, never fatal.
          results.push({ directoryName: entry.name, kind: "broken", path })
          continue
        }
        if (isPathSafe(canonicalReal, target) && target !== canonicalReal) {
          results.push({
            directoryName: entry.name,
            kind: "linkedTo",
            linkTarget: basename(target),
            path
          })
          continue
        }
        if (!(await isDirectory(path)) || !(await hasSkillFile(path))) continue
        results.push({
          directoryName: entry.name,
          document: await readSkillDocument(path, entry.name),
          hash: await skillContentHash(path),
          kind: "independent",
          path
        })
        continue
      }
      if (!entry.isDirectory()) continue
      if (!(await hasSkillFile(path))) continue
      results.push({
        directoryName: entry.name,
        document: await readSkillDocument(path, entry.name),
        hash: await skillContentHash(path),
        kind: "independent",
        path
      })
    }
    return results.sort((a, b) => a.directoryName.localeCompare(b.directoryName))
  }

  const list = async (): Promise<SkillsScan> => {
    const canonical = await listCanonical()
    const canonicalReal = await resolveExisting(canonicalDir)
    const byName = new Map(canonical.map((skill) => [skill.directoryName, skill]))
    const byHash = new Map(canonical.map((skill) => [skill.hash, skill]))

    const installs = new Map<string, Array<SkillHarnessInstall>>(
      canonical.map((skill) => [skill.directoryName, []])
    )
    const groups: Array<SkillsHarnessGroup> = []

    for (const definition of config.agents.catalog) {
      const spec = definition.skills
      if (spec === undefined) continue
      const skillsDir = resolveNativeConfigPath(spec.globalDir, { env, home })
      const skillsDirReal = await resolveExisting(skillsDir)

      const addInstall = (directoryName: string, state: SkillInstallState): void => {
        installs.get(directoryName)?.push({ harnessId: definition.id, state })
      }

      // A harness whose skills dir IS the canonical store (declared, or the
      // user symlinked it there) sees every global skill natively — and must
      // never receive per-skill links or a duplicate group listing.
      if (spec.readsCanonical === true || skillsDirReal === canonicalReal) {
        for (const skill of canonical) addInstall(skill.directoryName, "canonical")
        groups.push({
          harnessId: definition.id,
          harnessName: definition.name,
          harnessSymbol: definition.symbolName,
          skills: [],
          skillsDir
        })
        continue
      }

      const entries = await listHarnessEntries(skillsDir, canonicalReal)
      const seen = new Set<string>()
      const harnessSkills: Array<HarnessSkill> = []

      for (const entry of entries) {
        if (entry.kind === "linkedTo") {
          const target = byName.get(entry.linkTarget as string)
          if (target !== undefined) {
            seen.add(target.directoryName)
            addInstall(target.directoryName, "linked")
            continue
          }
          // Link into the canonical store, but the skill is gone: broken.
          harnessSkills.push({
            classification: "broken",
            directoryName: entry.directoryName,
            harnessId: definition.id,
            name: entry.directoryName,
            path: entry.path
          })
          continue
        }
        if (entry.kind === "broken") {
          harnessSkills.push({
            classification: "broken",
            directoryName: entry.directoryName,
            harnessId: definition.id,
            name: entry.directoryName,
            path: entry.path
          })
          continue
        }
        const sameName = byName.get(entry.directoryName)
        if (sameName !== undefined) {
          seen.add(sameName.directoryName)
          if (sameName.hash === entry.hash) {
            // Content-identical copy of the global skill: behaves installed.
            addInstall(sameName.directoryName, "copied")
            continue
          }
          // Same name, drifted content: surface both sides.
          addInstall(sameName.directoryName, "conflict")
        }
        const document = entry.document as SkillDocument
        const duplicateOf =
          sameName === undefined ? byHash.get(entry.hash as string)?.directoryName : undefined
        harnessSkills.push({
          classification: "independent",
          directoryName: entry.directoryName,
          ...(document.description === undefined ? {} : { description: document.description }),
          ...(duplicateOf === undefined ? {} : { duplicateOf }),
          harnessId: definition.id,
          ...(document.invalid ? { invalid: true } : {}),
          name: document.name,
          path: entry.path
        })
      }

      for (const skill of canonical) {
        if (seen.has(skill.directoryName)) continue
        // Harnesses that also scan the canonical store (OpenCode) see every
        // global skill without any link in their own directory.
        addInstall(
          skill.directoryName,
          spec.alsoReadsCanonical === true ? "canonical" : "notInstalled"
        )
      }

      groups.push({
        harnessId: definition.id,
        harnessName: definition.name,
        harnessSymbol: definition.symbolName,
        skills: harnessSkills,
        skillsDir
      })
    }

    const global: Array<GlobalSkill> = canonical.map((skill) => ({
      directoryName: skill.directoryName,
      ...(skill.document.description === undefined
        ? {}
        : { description: skill.document.description }),
      installs: installs.get(skill.directoryName) as ReadonlyArray<SkillHarnessInstall>,
      ...(skill.document.invalid ? { invalid: true } : {}),
      name: skill.document.name,
      path: skill.path
    }))

    return { canonicalDir, global, harnesses: groups }
  }

  return { isManagedSkill, list, listCanonical }
}
