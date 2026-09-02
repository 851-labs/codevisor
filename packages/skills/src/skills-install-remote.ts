import type { SkillsScan } from "@codevisor/api"
import { lstat, mkdtemp, readdir, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { basename, join } from "node:path"
import type { SkillsInstallContext } from "./skills-install-context.js"
import { importDirectory } from "./skills-install-create.js"
import { materializeWellKnownSkills, parseSkillSource } from "./skills-remote-source.js"
import {
  EXCLUDE_DIRS,
  hasSkillFile,
  isPathSafe,
  readSkillDocument,
  sanitizeName,
  SkillsError
} from "./skills-store.js"

/// Find skill folders (dirs containing SKILL.md) under a cloned source,
/// shallowly: the root itself, or descendants up to a few levels down —
/// enough for repo layouts like `skills/<name>/SKILL.md`.
const discoverSkillDirs = async (root: string, depth = 3): Promise<ReadonlyArray<string>> => {
  if (await hasSkillFile(root)) return [root]
  if (depth === 0) return []
  let entries
  try {
    entries = await readdir(root, { withFileTypes: true })
  } catch {
    return []
  }
  const found: Array<string> = []
  for (const entry of entries) {
    if (!entry.isDirectory()) continue
    if (EXCLUDE_DIRS.has(entry.name) || entry.name === "node_modules") continue
    found.push(...(await discoverSkillDirs(join(root, entry.name), depth - 1)))
  }
  return found.sort()
}

/// Discovering and importing skills from remote sources: git repositories
/// and well-known skill indexes, staged in a temporary clone.
export const makeSkillsRemoteOperations = (context: SkillsInstallContext) => {
  const { canonicalDir, cloneFn, installEverywhere, list } = context

  /// Materialize a remote source into a staging directory (git clone or
  /// well-known download) and return the discovery root.
  const materializeSource = async (source: string, staging: string): Promise<string> => {
    const parsed = parseSkillSource(source)
    if (parsed.kind === "wellKnown") {
      await materializeWellKnownSkills(parsed.url, staging)
      return staging
    }
    try {
      await cloneFn(parsed.url, parsed.ref, staging)
    } catch (cause) {
      throw new SkillsError(
        `Couldn't fetch ${parsed.url}${parsed.ref === undefined ? "" : ` (${parsed.ref})`}: ${
          cause instanceof Error ? cause.message : String(cause)
        }`,
        "invalid"
      )
    }
    if (parsed.subpath === undefined) return staging
    const candidate = join(staging, parsed.subpath)
    if (!isPathSafe(staging, candidate)) {
      throw new SkillsError(`Invalid source path: ${parsed.subpath}`, "invalid")
    }
    return candidate
  }

  const discoveredSkillDirs = async (
    source: string,
    staging: string
  ): Promise<ReadonlyArray<string>> => {
    const root = await materializeSource(source, staging)
    const skillDirs = await discoverSkillDirs(root)
    if (skillDirs.length === 0) {
      throw new SkillsError(`No SKILL.md found in ${source}`, "invalid")
    }
    return skillDirs
  }

  const discoverRemote = async (request: { readonly source: string }) => {
    const staging = await mkdtemp(join(tmpdir(), "codevisor-skill-import-"))
    try {
      const skillDirs = await discoveredSkillDirs(request.source, staging)
      const skills = []
      for (const dir of skillDirs) {
        const document = await readSkillDocument(dir, basename(dir))
        const directoryName = sanitizeName(
          document.invalid || document.name === "" ? basename(dir) : document.name
        )
        let alreadyExists = true
        try {
          await lstat(join(canonicalDir, directoryName))
        } catch {
          alreadyExists = false
        }
        skills.push({
          alreadyExists,
          ...(document.description === undefined ? {} : { description: document.description }),
          directoryName,
          name: document.name
        })
      }
      return { skills: skills.sort((a, b) => a.directoryName.localeCompare(b.directoryName)) }
    } finally {
      await rm(staging, { force: true, recursive: true })
    }
  }

  const importRemote = async (request: {
    readonly source: string
    readonly skillNames?: ReadonlyArray<string> | undefined
  }): Promise<SkillsScan> => {
    const staging = await mkdtemp(join(tmpdir(), "codevisor-skill-import-"))
    try {
      let skillDirs = await discoveredSkillDirs(request.source, staging)

      // Multi-skill sources can be narrowed to a selection (matched against
      // the sanitized directory name or the frontmatter name).
      const requested = request.skillNames?.map((name) => sanitizeName(name))
      if (requested !== undefined && requested.length > 0) {
        const matched: Array<string> = []
        for (const dir of skillDirs) {
          const document = await readSkillDocument(dir, basename(dir))
          // readSkillDocument always yields a non-empty name (frontmatter
          // name or the directory name), so both forms match directly.
          const candidates = [sanitizeName(basename(dir)), sanitizeName(document.name)]
          if (requested.some((name) => candidates.includes(name))) matched.push(dir)
        }
        if (matched.length === 0) {
          throw new SkillsError(
            `None of the requested skills were found in ${request.source}`,
            "notFound"
          )
        }
        skillDirs = matched
      }

      const imported: Array<string> = []
      const conflicts: Array<string> = []
      for (const dir of skillDirs) {
        const { directoryName, outcome } = await importDirectory(canonicalDir, dir)
        if (outcome === "imported") imported.push(directoryName)
        if (outcome === "conflict") conflicts.push(basename(dir))
      }
      if (imported.length === 0) {
        throw new SkillsError(
          `Every skill in ${request.source} already exists (${conflicts.join(", ")})`,
          "conflict"
        )
      }
      await installEverywhere(imported)
      return list()
    } finally {
      await rm(staging, { force: true, recursive: true })
    }
  }

  return { discoverRemote, importRemote }
}
