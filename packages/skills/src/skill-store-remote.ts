import { mkdtemp, readdir, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { basename, join } from "node:path"

import type { SkillsList } from "@codevisor/api"

import { exists, importDirectory, importedDirectoryName } from "./skill-import.js"
import { materializeWellKnownSkills, parseSkillSource } from "./skills-remote-source.js"
import {
  EXCLUDE_DIRS,
  hasSkillFile,
  isPathSafe,
  readSkillDocument,
  sanitizeName,
  SkillsError
} from "./skills-store.js"

/// Find skill folders (dirs containing SKILL.md) under a fetched source,
/// shallowly: the root itself, or descendants a few levels down — enough
/// for repo layouts like `skills/<name>/SKILL.md`.
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
  return found.toSorted()
}

export interface RemoteSkillDeps {
  readonly dir: string
  readonly clone: (url: string, ref: string | undefined, destination: string) => Promise<void>
  readonly list: () => Promise<SkillsList>
  readonly onImported: () => void
}

/// Discovering and importing skills from remote sources (git repositories
/// and well-known skill indexes) into the store, staged in a temp folder.
export const makeRemoteSkillOperations = (deps: RemoteSkillDeps) => {
  const { dir } = deps

  const materializeSource = async (source: string, staging: string): Promise<string> => {
    const parsed = parseSkillSource(source)
    if (parsed.kind === "wellKnown") {
      await materializeWellKnownSkills(parsed.url, staging)
      return staging
    }
    try {
      await deps.clone(parsed.url, parsed.ref, staging)
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

  const withSkillDirs = async <A>(
    source: string,
    use: (skillDirs: ReadonlyArray<string>) => Promise<A>
  ): Promise<A> => {
    const staging = await mkdtemp(join(tmpdir(), "codevisor-skill-import-"))
    try {
      const skillDirs = await discoverSkillDirs(await materializeSource(source, staging))
      if (skillDirs.length === 0) {
        throw new SkillsError(`No SKILL.md found in ${source}`, "invalid")
      }
      return await use(skillDirs)
    } finally {
      await rm(staging, { force: true, recursive: true })
    }
  }

  const discoverRemote = (request: { readonly source: string }) =>
    withSkillDirs(request.source, async (skillDirs) => {
      const skills = []
      for (const skillDir of skillDirs) {
        const document = await readSkillDocument(skillDir, basename(skillDir))
        const directoryName = await importedDirectoryName(skillDir)
        skills.push({
          alreadyExists: await exists(join(dir, directoryName)),
          ...(document.description === undefined ? {} : { description: document.description }),
          directoryName,
          name: document.name
        })
      }
      return { skills: skills.toSorted((a, b) => a.directoryName.localeCompare(b.directoryName)) }
    })

  const importRemote = (request: {
    readonly source: string
    readonly skillNames?: ReadonlyArray<string> | undefined
  }): Promise<SkillsList> =>
    withSkillDirs(request.source, async (found) => {
      let skillDirs = found
      // Multi-skill sources can be narrowed to a selection, matched against
      // the sanitized folder name or the frontmatter name.
      const requested = request.skillNames?.map((name) => sanitizeName(name))
      if (requested !== undefined && requested.length > 0) {
        const matched: Array<string> = []
        for (const skillDir of skillDirs) {
          const document = await readSkillDocument(skillDir, basename(skillDir))
          const candidates = new Set([
            sanitizeName(basename(skillDir)),
            sanitizeName(document.name)
          ])
          if (requested.some((name) => candidates.has(name))) matched.push(skillDir)
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
      const skipped: Array<string> = []
      for (const skillDir of skillDirs) {
        const { directoryName, outcome } = await importDirectory(dir, skillDir)
        if (outcome === "imported") imported.push(directoryName)
        else skipped.push(basename(skillDir))
      }
      if (imported.length === 0) {
        throw new SkillsError(
          `Every skill in ${request.source} already exists (${skipped.join(", ")})`,
          "conflict"
        )
      }
      deps.onImported()
      return deps.list()
    })

  return { discoverRemote, importRemote }
}
