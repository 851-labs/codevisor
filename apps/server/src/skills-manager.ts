import type {
  GlobalSkill,
  HarnessSkill,
  SkillHarnessInstall,
  SkillInstallState,
  SkillsHarnessGroup,
  SkillsScan
} from "@codevisor/api"
import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import {
  chmod,
  cp,
  lstat,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  readlink,
  realpath,
  rename,
  rm,
  stat,
  symlink,
  writeFile
} from "node:fs/promises"
import { homedir, tmpdir } from "node:os"
import { basename, dirname, join, normalize, relative, resolve, sep } from "node:path"
import { parse as parseYaml } from "yaml"
import { resolveNativeConfigPath } from "./native-config-files.js"

/// Skills management over the canonical ~/.agents/skills store and each
/// harness's own skills directory. The symlink classification in `list` is
/// what every write operation trusts, so both follow the vercel-labs skills
/// installer's realpath discipline exactly. Iron rules for writes: lstat
/// before every rm, links are removed non-recursively (never followed), and
/// recursive removal only happens inside the canonical store or on
/// hash-verified duplicate copies.
export interface SkillsManager {
  readonly list: () => Promise<SkillsScan>
  /// Create a new skill in the canonical store — from a template, or from
  /// pasted SKILL.md content.
  readonly create: (request: {
    readonly name: string
    readonly description: string
    readonly content?: string | undefined
  }) => Promise<SkillsScan>
  /// Copy a local skill folder into the canonical store.
  readonly importLocal: (request: { readonly path: string }) => Promise<SkillsScan>
  /// Fetch skills from a remote source (GitHub/GitLab repos, git URLs, or
  /// sites publishing skills via RFC 8615 well-known endpoints — the
  /// `npx skills` formats) into the canonical store. `skillNames` limits the
  /// import to specific skills from a multi-skill source.
  readonly importRemote: (request: {
    readonly source: string
    readonly skillNames?: ReadonlyArray<string> | undefined
  }) => Promise<SkillsScan>
  /// List the skills a remote source offers without importing anything —
  /// the picker step for multi-skill sources.
  readonly discoverRemote: (request: { readonly source: string }) => Promise<{
    readonly skills: ReadonlyArray<{
      readonly name: string
      readonly directoryName: string
      readonly description?: string | undefined
      readonly alreadyExists: boolean
    }>
  }>
  /// Delete a canonical skill and sweep now-dangling links from every
  /// harness skills directory.
  readonly remove: (directoryName: string) => Promise<SkillsScan>
  /// Install (relative symlink, copy fallback) or uninstall a canonical
  /// skill for one harness.
  readonly setInstalled: (
    directoryName: string,
    harnessId: string,
    installed: boolean
  ) => Promise<SkillsScan>
  /// Move an independent harness-dir skill into the canonical store and
  /// symlink it back.
  readonly makeGlobal: (harnessId: string, directoryName: string) => Promise<SkillsScan>
  /// Bring harnesses in sync with the canonical store: link the given
  /// skills (or every global skill) into every link-based harness,
  /// best-effort — conflicting copies are left alone.
  readonly sync: (request?: {
    readonly directoryNames?: ReadonlyArray<string> | undefined
  }) => Promise<SkillsScan>
}

/// Typed failure the HTTP layer maps to a status code: invalid → 400,
/// notFound → 404, conflict → 409.
export class SkillsError extends Error {
  constructor(
    message: string,
    readonly code: "invalid" | "notFound" | "conflict"
  ) {
    super(message)
    this.name = "SkillsError"
  }
}

export interface SkillsManagerConfig {
  readonly agents: AgentRuntimeService
  /// Seams for tests; production uses the real home dir and process env.
  readonly homedir?: string
  readonly env?: Readonly<Record<string, string | undefined>>
  /// Failure-injection seams for syscalls that are hard to break for real
  /// (symlink-unsupported filesystems, cross-device renames).
  readonly overrides?: {
    readonly symlink?: typeof symlink
    readonly rename?: typeof rename
    readonly clone?: (url: string, ref: string | undefined, destination: string) => Promise<void>
  }
}

export const CANONICAL_SKILLS_DIR = "~/.agents/skills"

/// Kebab-case a skill directory name, converting path-traversal attempts and
/// special characters into hyphens. Ported from skills installer.ts.
export const sanitizeName = (name: string): string => {
  const sanitized = name
    .toLowerCase()
    .replace(/[^a-z0-9._]+/g, "-")
    .replace(/^[.\-]+|[.\-]+$/g, "")
  return sanitized.substring(0, 255) || "unnamed-skill"
}

/// True when targetPath is basePath or lives inside it. Ported from skills
/// installer.ts; every destructive path decision must pass through this.
export const isPathSafe = (basePath: string, targetPath: string): boolean => {
  const normalizedBase = normalize(resolve(basePath))
  const normalizedTarget = normalize(resolve(targetPath))
  return normalizedTarget.startsWith(normalizedBase + sep) || normalizedTarget === normalizedBase
}

/// True when either path contains the other — the "installing a skill onto
/// its own source" guard. Ported from skills installer.ts.
export const pathsOverlap = (pathA: string, pathB: string): boolean =>
  isPathSafe(pathA, pathB) || isPathSafe(pathB, pathA)

const resolveSymlinkTarget = (linkPath: string, linkTarget: string): string =>
  resolve(dirname(linkPath), linkTarget)

/// Minimal YAML-only frontmatter parser. Deliberately not gray-matter, whose
/// built-in `---js` engine is an eval() RCE. Ported from skills frontmatter.ts.
export const parseFrontmatter = (
  raw: string
): { readonly data: Record<string, unknown>; readonly content: string } => {
  const match = raw.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/)
  if (match === null) return { content: raw, data: {} }
  const data = (parseYaml(match[1] as string) ?? {}) as Record<string, unknown>
  if (typeof data !== "object" || Array.isArray(data)) {
    throw new Error("frontmatter is not a mapping")
  }
  // Both capture groups always participate in a successful match.
  return { content: match[2] as string, data }
}

const EXCLUDE_FILES: ReadonlySet<string> = new Set(["metadata.json"])
const EXCLUDE_DIRS: ReadonlySet<string> = new Set([".git", "__pycache__", "__pypackages__"])

/// sha256 over the skill folder's sorted relative paths and file contents —
/// two directories hash equal iff their meaningful contents are identical.
/// Used to recognize independent copies of canonical skills.
export const skillContentHash = async (dir: string): Promise<string> => {
  const hash = createHash("sha256")
  const walk = async (current: string, prefix: string): Promise<void> => {
    const entries = await readdir(current, { withFileTypes: true })
    const names = entries.map((entry) => entry.name).sort()
    for (const name of names) {
      const entry = entries.find((candidate) => candidate.name === name) as (typeof entries)[number]
      const entryPath = join(current, name)
      const relative = prefix === "" ? name : `${prefix}/${name}`
      if (entry.isDirectory() || (entry.isSymbolicLink() && (await isDirectory(entryPath)))) {
        if (EXCLUDE_DIRS.has(name)) continue
        hash.update(`d:${relative}\n`)
        await walk(entryPath, relative)
        continue
      }
      if (EXCLUDE_FILES.has(name)) continue
      try {
        const content = await readFile(entryPath)
        hash.update(`f:${relative}:${content.length}\n`)
        hash.update(content)
      } catch {
        // Unreadable file (broken symlink inside the skill): fold its
        // presence into the hash without contents.
        hash.update(`x:${relative}\n`)
      }
    }
  }
  await walk(dir, "")
  return hash.digest("hex")
}

const isDirectory = async (path: string): Promise<boolean> => {
  try {
    return (await stat(path)).isDirectory()
  } catch {
    return false
  }
}

/// Recursive skill-folder copy, ported from skills installer.ts: excluded
/// entries skipped, file symlinks dereferenced (remote-skill links rarely
/// survive relocation), permissions preserved, broken symlinks skipped
/// instead of aborting the copy.
export const copyDirectory = async (src: string, dest: string): Promise<void> => {
  await mkdir(dest, { recursive: true })
  const entries = await readdir(src, { withFileTypes: true })
  await Promise.all(
    entries
      .filter(
        (entry) =>
          !EXCLUDE_FILES.has(entry.name) && !(entry.isDirectory() && EXCLUDE_DIRS.has(entry.name))
      )
      .map(async (entry) => {
        const srcPath = join(src, entry.name)
        const destPath = join(dest, entry.name)
        if (entry.isDirectory()) {
          await copyDirectory(srcPath, destPath)
          return
        }
        try {
          await cp(srcPath, destPath, { dereference: true, recursive: true })
          const sourceStats = await stat(srcPath)
          await chmod(destPath, sourceStats.mode & 0o777)
        } catch (cause) {
          // Broken symlinks (absolute paths from another machine) are
          // skipped, not fatal.
          const isBrokenLink =
            cause instanceof Error &&
            (cause as NodeJS.ErrnoException).code === "ENOENT" &&
            entry.isSymbolicLink()
          /* v8 ignore next -- non-ENOENT copy failures (permissions, I/O) require an environment tests can't fake. */
          if (!isBrokenLink) throw cause
        }
      })
  )
}

/// Resolve a path's parent directory through symlinks, keeping the final
/// component. Ported from skills installer.ts — this is what makes a
/// user-symlinked `~/.claude/skills -> ~/.agents/skills` read as canonical.
export const resolveParentSymlinks = async (path: string): Promise<string> => {
  const resolved = resolve(path)
  try {
    const realDir = await realpath(dirname(resolved))
    return join(realDir, basename(resolved))
  } catch {
    return resolved
  }
}

interface SkillDocument {
  readonly name: string
  readonly description: string | undefined
  readonly invalid: boolean
}

/// Parse SKILL.md tolerantly: malformed frontmatter degrades to the directory
/// name plus an `invalid` badge, never a scan failure.
const readSkillDocument = async (dir: string, directoryName: string): Promise<SkillDocument> => {
  try {
    const raw = await readFile(join(dir, "SKILL.md"), "utf8")
    const { data } = parseFrontmatter(raw)
    const name =
      typeof data["name"] === "string" && data["name"] !== "" ? data["name"] : directoryName
    const description = typeof data["description"] === "string" ? data["description"] : undefined
    return { description, invalid: false, name }
  } catch {
    return { description: undefined, invalid: true, name: directoryName }
  }
}

const hasSkillFile = async (dir: string): Promise<boolean> => {
  try {
    return (await stat(join(dir, "SKILL.md"))).isFile()
  } catch {
    return false
  }
}

interface CanonicalSkill {
  readonly directoryName: string
  readonly path: string
  readonly document: SkillDocument
  readonly hash: string
}

interface HarnessEntry {
  readonly directoryName: string
  readonly path: string
  readonly kind: "linkedTo" | "independent" | "broken"
  /// For `linkedTo`: the canonical directory name the link resolves to.
  readonly linkTarget?: string
  readonly hash?: string
  readonly document?: SkillDocument
}

export const makeSkillsManager = (config: SkillsManagerConfig): SkillsManager => {
  const home = config.homedir ?? homedir()
  const env = config.env ?? process.env

  const canonicalDir = resolveNativeConfigPath(CANONICAL_SKILLS_DIR, { env, home })

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

  const symlinkFn = config.overrides?.symlink ?? symlink
  const renameFn = config.overrides?.rename ?? rename
  const cloneFn = config.overrides?.clone ?? cloneSkillSource

  /// A directory name that must reference a direct child of `base`. Rejects
  /// separators and traversal before any path is built from API input.
  const assertSafeChild = (base: string, name: string): string => {
    const child = join(base, name)
    if (
      name === "" ||
      name === "." ||
      name === ".." ||
      name.includes("/") ||
      name.includes("\\") ||
      basename(child) !== name ||
      !isPathSafe(base, child)
    ) {
      throw new SkillsError(`Invalid skill directory name: ${name}`, "invalid")
    }
    return child
  }

  const harnessSkillsDir = (
    harnessId: string
  ): { dir: string; readsCanonical: boolean; alsoReadsCanonical: boolean } => {
    const definition = config.agents.catalog.find((candidate) => candidate.id === harnessId)
    const spec = definition?.skills
    if (definition === undefined || spec === undefined) {
      throw new SkillsError(`Harness ${harnessId} does not support skills`, "notFound")
    }
    return {
      dir: resolveNativeConfigPath(spec.globalDir, { env, home }),
      readsCanonical: spec.readsCanonical === true,
      alsoReadsCanonical: spec.alsoReadsCanonical === true
    }
  }

  /// Remove a filesystem entry with the iron rules applied: links are
  /// removed as links (never followed, never recursive). Callers must have
  /// already proven a real directory is safe to delete (inside the canonical
  /// store, or hash-verified against it) before reaching this.
  const safeRemove = async (path: string): Promise<void> => {
    let stats
    try {
      stats = await lstat(path)
    } catch {
      /* v8 ignore next 2 -- TOCTOU defense: every caller lstats first. */
      return
    }
    if (stats.isSymbolicLink() || !stats.isDirectory()) {
      await rm(path, { force: true })
      return
    }
    await rm(path, { force: true, recursive: true })
  }

  /// Create a relative symlink from a harness dir into the canonical store.
  /// Ported from skills installer.ts createSymlink with one deliberate
  /// divergence: an existing real directory at the link path throws
  /// `conflict` instead of being silently destroyed.
  /// Returns "linked" | "noop" (physically same location) | "failed"
  /// (symlink syscall failed — caller falls back to copy).
  const createSkillLink = async (
    target: string,
    linkPath: string
  ): Promise<"linked" | "noop" | "failed"> => {
    const resolvedTarget = resolve(target)
    const resolvedLinkPath = resolve(linkPath)

    // Realpath both sides (directly, then through symlinked parents): when
    // they're physically the same location, creating a link would produce a
    // self-reference (ELOOP) — the skill is already visible there.
    // The target is a canonical skill callers have already verified exists,
    // so its realpath never needs a fallback.
    const realTarget = await realpath(resolvedTarget)
    const realLinkPath = await realpath(resolvedLinkPath).catch(() => resolvedLinkPath)
    if (realTarget === realLinkPath) return "noop"
    const realTargetWithParents = await resolveParentSymlinks(target)
    const realLinkPathWithParents = await resolveParentSymlinks(linkPath)
    /* v8 ignore next -- defense in depth: setInstalled/makeGlobal reject canonical-aliased dirs before linking, but this guard is what makes createSkillLink safe standalone (installer.ts:214-221). */
    if (realTargetWithParents === realLinkPathWithParents) return "noop"

    try {
      const stats = await lstat(linkPath)
      // DIVERGENCE from installer.ts: never destroy an existing real entry —
      // surface it and let Make Global resolve the conflict. Defense in
      // depth: setInstalled resolves real-dir cases (identical copy / drift)
      // before linking, so this is unreachable through the public API.
      /* v8 ignore next 6 */
      if (!stats.isSymbolicLink()) {
        throw new SkillsError(
          `A skill already exists at ${linkPath} — make it global instead`,
          "conflict"
        )
      }
      // Stale, circular, or differently-targeted link: replace it. (A link
      // already resolving to the target short-circuits at the realpath
      // check above, so anything still here is wrong or dangling.)
      await rm(linkPath, { force: true })
    } catch (cause) {
      /* v8 ignore next -- only the defensive real-dir branch above throws SkillsError. */
      if (cause instanceof SkillsError) throw cause
      // ENOENT = nothing there yet; continue to creation. (lstat does not
      // follow links, so even circular links land in the branch above.)
    }

    try {
      const linkDir = dirname(linkPath)
      await mkdir(linkDir, { recursive: true })
      // Relative link computed against the realpathed parent so it stays
      // correct even when the harness dir itself is a symlink.
      const realLinkDir = await resolveParentSymlinks(linkDir)
      await symlinkFn(relative(realLinkDir, resolvedTarget), linkPath)
      return "linked"
    } catch {
      return "failed"
    }
  }

  const canonicalSkillPath = async (directoryName: string): Promise<string> => {
    const path = assertSafeChild(canonicalDir, directoryName)
    if (!(await isDirectory(path)) || !(await hasSkillFile(path))) {
      throw new SkillsError(`No global skill named ${directoryName}`, "notFound")
    }
    return path
  }

  const create = async (request: {
    readonly name: string
    readonly description: string
    readonly content?: string | undefined
  }): Promise<SkillsScan> => {
    const trimmedName = request.name.trim()
    if (trimmedName === "") throw new SkillsError("Skill name is required", "invalid")
    const description = request.description.trim()
    const pasted = request.content?.trim() ?? ""

    // Pasted content that already carries frontmatter is written verbatim
    // (its own name wins for the directory); otherwise frontmatter from the
    // form fields is prepended to whatever body we have.
    let skillFile: string
    let namingSource = trimmedName
    if (pasted.startsWith("---")) {
      skillFile = `${pasted}\n`
      try {
        const { data } = parseFrontmatter(skillFile)
        if (typeof data["name"] === "string" && data["name"] !== "") {
          namingSource = data["name"]
        }
      } catch {
        throw new SkillsError("The pasted SKILL.md frontmatter is not valid YAML", "invalid")
      }
    } else {
      const body =
        pasted !== ""
          ? pasted
          : [
              description === "" ? trimmedName : description,
              "",
              "## Instructions",
              "",
              "Describe the steps the agent should follow when this skill applies."
            ].join("\n")
      skillFile = [
        "---",
        `name: ${JSON.stringify(trimmedName)}`,
        `description: ${JSON.stringify(description === "" ? trimmedName : description)}`,
        "---",
        "",
        body,
        ""
      ].join("\n")
    }

    const directoryName = sanitizeName(namingSource)
    const path = assertSafeChild(canonicalDir, directoryName)
    try {
      await lstat(path)
      throw new SkillsError(`A skill named ${directoryName} already exists`, "conflict")
    } catch (cause) {
      if (cause instanceof SkillsError) throw cause
    }
    await mkdir(path, { recursive: true })
    await writeFile(join(path, "SKILL.md"), skillFile, "utf8")
    // New skills are immediately usable everywhere.
    await installEverywhere([directoryName])
    return list()
  }

  /// Copy one on-disk skill folder into the canonical store. Returns the
  /// outcome instead of throwing on conflicts so multi-skill imports can
  /// report per-skill results.
  const importDirectory = async (
    source: string
  ): Promise<{
    readonly outcome: "imported" | "conflict" | "selfImport"
    readonly directoryName: string
  }> => {
    const document = await readSkillDocument(source, basename(source))
    const directoryName = sanitizeName(
      document.invalid || document.name === "" ? basename(source) : document.name
    )
    const destination = assertSafeChild(canonicalDir, directoryName)
    // Never import a skill onto (or inside) itself — cleaning the
    // destination would destroy the source (installer.ts pathsOverlap skip).
    if (pathsOverlap(source, destination)) return { directoryName, outcome: "selfImport" }
    try {
      await lstat(destination)
      return { directoryName, outcome: "conflict" }
    } catch {
      // Destination free — proceed.
    }
    await copyDirectory(source, destination)
    return { directoryName, outcome: "imported" }
  }

  const importLocal = async (request: { readonly path: string }): Promise<SkillsScan> => {
    const source = resolve(request.path)
    if (!(await isDirectory(source))) {
      throw new SkillsError(`Not a directory: ${request.path}`, "invalid")
    }
    if (!(await hasSkillFile(source))) {
      throw new SkillsError(`No SKILL.md found in ${request.path}`, "invalid")
    }
    const { directoryName, outcome } = await importDirectory(source)
    if (outcome === "conflict") {
      throw new SkillsError(`A skill named ${basename(source)} already exists`, "conflict")
    }
    if (outcome === "imported") await installEverywhere([directoryName])
    return list()
  }

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
        const { directoryName, outcome } = await importDirectory(dir)
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

  /// Link (or copy-fallback) one canonical skill into one harness skills
  /// directory. Throws SkillsError conflict for drifted same-name copies.
  const installIntoDir = async (
    directoryName: string,
    skillsDir: string,
    harnessLabel: string
  ): Promise<void> => {
    const linkPath = assertSafeChild(skillsDir, directoryName)
    const canonicalPath = await canonicalSkillPath(directoryName)
    let existing
    try {
      existing = await lstat(linkPath)
    } catch {
      existing = undefined
    }
    if (existing !== undefined && !existing.isSymbolicLink() && existing.isDirectory()) {
      // An independent copy already sits there. Identical content means
      // it's already effectively installed; drifted content is a conflict.
      if ((await skillContentHash(linkPath)) === (await skillContentHash(canonicalPath))) {
        return
      }
      throw new SkillsError(
        `${directoryName} exists in ${harnessLabel} with different content — resolve the conflict first`,
        "conflict"
      )
    }
    const result = await createSkillLink(canonicalPath, linkPath)
    if (result === "failed") {
      // Symlink-hostile filesystem: degrade to a tracked copy.
      await copyDirectory(canonicalPath, linkPath)
    }
  }

  /// New and imported skills should be usable immediately: link them into
  /// every harness that needs a link, best-effort — a drifted copy in one
  /// harness must not fail the creation itself.
  const installEverywhere = async (directoryNames: ReadonlyArray<string>): Promise<void> => {
    const canonicalReal = await resolveExisting(canonicalDir)
    for (const definition of config.agents.catalog) {
      const spec = definition.skills
      if (spec === undefined || spec.readsCanonical === true || spec.alsoReadsCanonical === true) {
        continue
      }
      const skillsDir = resolveNativeConfigPath(spec.globalDir, { env, home })
      if ((await resolveExisting(skillsDir)) === canonicalReal) continue
      for (const directoryName of directoryNames) {
        try {
          await installIntoDir(directoryName, skillsDir, definition.name)
        } catch (cause) {
          /* v8 ignore next -- only SkillsError conflicts are expected; anything else should surface. */
          if (!(cause instanceof SkillsError)) throw cause
        }
      }
    }
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

  return {
    create,
    discoverRemote,
    importLocal,
    importRemote,
    list,
    makeGlobal,
    remove,
    setInstalled,
    sync
  }
}

/// A skill source: something git can clone, or a site publishing skills via
/// RFC 8615 well-known endpoints.
export type ParsedSkillSource =
  | {
      readonly kind: "git"
      readonly url: string
      readonly ref?: string | undefined
      readonly subpath?: string | undefined
    }
  | { readonly kind: "wellKnown"; readonly url: string }

/// Parse the `npx skills` source formats: GitHub/GitLab `owner/repo`
/// shorthand (with optional `#ref` and `/subpath`), `github:`/`gitlab:`
/// prefixes, repository URLs (including `/tree/...` and GitLab `/-/tree/...`
/// paths), raw git/ssh URLs, local paths — and any other HTTP(S) URL, which
/// resolves through the site's `/.well-known/agent-skills` endpoint.
export const parseSkillSource = (input: string): ParsedSkillSource => {
  let source = input.trim()
  if (source === "") throw new SkillsError("A skill source is required", "invalid")
  let forcedHost: "github.com" | "gitlab.com" = "github.com"
  if (source.startsWith("github:")) source = source.slice("github:".length)
  if (source.startsWith("gitlab:")) {
    forcedHost = "gitlab.com"
    source = source.slice("gitlab:".length)
  }

  // Raw git/ssh URLs pass straight through (with optional #ref).
  if (source.startsWith("git@") || source.startsWith("ssh://")) {
    const [url, ref] = splitRef(source)
    return { kind: "git", ref, url }
  }

  // Local filesystem paths clone directly (useful for testing and local
  // skill repositories), with the same optional #ref suffix.
  if (source.startsWith("/") || source.startsWith("./") || source.startsWith("../")) {
    const [url, ref] = splitRef(source)
    return { kind: "git", ref, url }
  }

  if (source.startsWith("http://") || source.startsWith("https://")) {
    const [withoutRef, ref] = splitRef(source)
    const url = new URL(withoutRef)
    if (url.hostname === "github.com" || url.hostname === "www.github.com") {
      const segments = url.pathname.split("/").filter((part) => part !== "")
      const [owner, repoRaw, marker, treeRef, ...rest] = segments
      if (owner === undefined || repoRaw === undefined) {
        throw new SkillsError(`Not a repository URL: ${input}`, "invalid")
      }
      const repo = repoRaw.endsWith(".git") ? repoRaw.slice(0, -4) : repoRaw
      // github.com/o/r/tree/<ref>/<subpath...>
      if (marker === "tree" && treeRef !== undefined) {
        return {
          kind: "git",
          ref: ref ?? treeRef,
          ...(rest.length === 0 ? {} : { subpath: rest.join("/") }),
          url: `https://github.com/${owner}/${repo}.git`
        }
      }
      const subpath = [marker, treeRef, ...rest].filter(
        (part): part is string => part !== undefined
      )
      return {
        kind: "git",
        ref,
        ...(subpath.length === 0 ? {} : { subpath: subpath.join("/") }),
        url: `https://github.com/${owner}/${repo}.git`
      }
    }
    if (url.hostname === "gitlab.com" || url.hostname === "www.gitlab.com") {
      const segments = url.pathname.split("/").filter((part) => part !== "")
      // GitLab tree URLs use a `/-/tree/<ref>/<subpath...>` marker, with the
      // repository path (including subgroups) before the `-`.
      const dashIndex = segments.indexOf("-")
      const repoSegments = dashIndex === -1 ? segments : segments.slice(0, dashIndex)
      if (repoSegments.length < 2) {
        throw new SkillsError(`Not a repository URL: ${input}`, "invalid")
      }
      const last = repoSegments[repoSegments.length - 1] as string
      const repoPath = [
        ...repoSegments.slice(0, -1),
        last.endsWith(".git") ? last.slice(0, -4) : last
      ].join("/")
      if (dashIndex !== -1 && segments[dashIndex + 1] === "tree") {
        const treeRef = segments[dashIndex + 2]
        const rest = segments.slice(dashIndex + 3)
        return {
          kind: "git",
          ref: ref ?? treeRef,
          ...(rest.length === 0 ? {} : { subpath: rest.join("/") }),
          url: `https://gitlab.com/${repoPath}.git`
        }
      }
      return { kind: "git", ref, url: `https://gitlab.com/${repoPath}.git` }
    }
    // Explicit git remotes clone; anything else is a site that may publish
    // skills via its well-known endpoint.
    if (withoutRef.endsWith(".git")) {
      return { kind: "git", ref, url: withoutRef }
    }
    return { kind: "wellKnown", url: withoutRef }
  }

  // owner/repo[#ref][/subpath] shorthand.
  const [withoutRef, ref] = splitRef(source)
  const segments = withoutRef.split("/").filter((part) => part !== "")
  const [owner, repo, ...subpath] = segments
  if (owner === undefined || repo === undefined) {
    throw new SkillsError(
      `Unrecognized skill source: ${input} — use owner/repo, owner/repo/path, or a git URL`,
      "invalid"
    )
  }
  return {
    kind: "git",
    ref,
    ...(subpath.length === 0 ? {} : { subpath: subpath.join("/") }),
    url: `https://${forcedHost}/${owner}/${repo}.git`
  }
}

/// Download skills published via RFC 8615 well-known endpoints into a
/// staging directory. Mirrors the `npx skills` provider: probes
/// `.well-known/agent-skills/index.json` (then the legacy
/// `.well-known/skills/index.json`) against both the given URL path and the
/// site origin, and supports both index formats — legacy per-file listings
/// and v0.2.0 single artifacts (`skill-md` files or zip/tar.gz archives with
/// sha256 digests).
const materializeWellKnownSkills = async (sourceUrl: string, staging: string): Promise<void> => {
  const trimmed = sourceUrl.replace(/\/+$/, "")
  const origin = new URL(trimmed).origin
  const bases = [...new Set([trimmed, origin])]
  const wellKnownPaths = [".well-known/agent-skills", ".well-known/skills"]

  let entries: ReadonlyArray<Record<string, unknown>> | undefined
  let indexDir: string | undefined
  for (const base of bases) {
    for (const path of wellKnownPaths) {
      const indexUrl = `${base}/${path}/index.json`
      try {
        const response = await fetch(indexUrl)
        if (!response.ok) continue
        const parsed = (await response.json()) as { skills?: unknown }
        if (!Array.isArray(parsed.skills)) continue
        entries = parsed.skills.filter(
          (entry): entry is Record<string, unknown> => entry !== null && typeof entry === "object"
        )
        indexDir = `${base}/${path}`
        break
      } catch {
        // Unreachable host or invalid JSON at this candidate — try the next.
      }
    }
    if (entries !== undefined) break
  }
  if (entries === undefined || indexDir === undefined || entries.length === 0) {
    throw new SkillsError(
      `No skills found at ${sourceUrl} — the site needs a .well-known/agent-skills/index.json`,
      "invalid"
    )
  }

  for (const entry of entries) {
    const name = typeof entry["name"] === "string" ? entry["name"] : undefined
    if (name === undefined || name === "") continue
    const directory = join(staging, sanitizeName(name))
    try {
      if (Array.isArray(entry["files"])) {
        // Legacy format: fetch each listed file from <indexDir>/<name>/.
        await mkdir(directory, { recursive: true })
        for (const file of entry["files"]) {
          if (typeof file !== "string") continue
          const destination = join(directory, file)
          if (!isPathSafe(directory, destination)) continue
          const response = await fetch(`${indexDir}/${encodeURIComponent(name)}/${file}`)
          if (!response.ok) throw new Error(`Failed to fetch ${file}`)
          await mkdir(dirname(destination), { recursive: true })
          await writeFile(destination, Buffer.from(await response.arrayBuffer()))
        }
        continue
      }
      const artifactUrl = typeof entry["url"] === "string" ? entry["url"] : undefined
      if (artifactUrl === undefined) continue
      const response = await fetch(new URL(artifactUrl, `${indexDir}/`))
      if (!response.ok) throw new Error(`Failed to fetch ${artifactUrl}`)
      const bytes = Buffer.from(await response.arrayBuffer())
      const digest = entry["digest"]
      if (typeof digest === "string" && digest.startsWith("sha256:")) {
        const actual = `sha256:${createHash("sha256").update(bytes).digest("hex")}`
        if (actual !== digest) throw new Error("Artifact digest mismatch")
      }
      await mkdir(directory, { recursive: true })
      if (entry["type"] === "skill-md") {
        await writeFile(join(directory, "SKILL.md"), bytes)
        continue
      }
      await extractArchive(bytes, directory)
    } catch {
      // A broken entry never poisons the rest of the index; the skill is
      // simply absent from discovery.
      await rm(directory, { force: true, recursive: true })
    }
  }
}

/// Extract a zip or tar.gz artifact (detected by magic bytes) with the
/// system tools — bsdtar and unzip both sanitize `..`/absolute entries, and
/// discovery re-validates every path before anything reaches the store.
const extractArchive = async (bytes: Buffer, directory: string): Promise<void> => {
  const artifact = join(directory, `.artifact-${randomUUIDForArtifact()}`)
  await writeFile(artifact, bytes)
  try {
    const isZip = bytes[0] === 0x50 && bytes[1] === 0x4b
    const isGzip = bytes[0] === 0x1f && bytes[1] === 0x8b
    if (!isZip && !isGzip) throw new Error("Unsupported archive format")
    const [command, args] = isZip
      ? ["unzip", ["-q", "-o", artifact, "-d", directory]]
      : ["tar", ["-xzf", artifact, "-C", directory]]
    await new Promise<void>((resolvePromise, rejectPromise) => {
      const child = spawn(command as string, args as Array<string>)
      const stderr: Array<string> = []
      child.stderr.setEncoding("utf8")
      child.stderr.on("data", (chunk: string) => stderr.push(chunk))
      /* v8 ignore next -- spawn-level failures (tool missing) need an environment tests can't fake. */
      child.on("error", (cause) => rejectPromise(cause))
      child.on("close", (code) => {
        if (code === 0) {
          resolvePromise()
          return
        }
        const reason = stderr.join("").trim()
        /* v8 ignore next -- tar and unzip always write a failure reason to stderr; exit-code fallback is a backstop. */
        rejectPromise(new Error(reason === "" ? `extraction exited with ${code}` : reason))
      })
    })
  } finally {
    await rm(artifact, { force: true })
  }
}

/* v8 ignore next 2 -- trivial indirection so artifact temp names stay unique without Date/Math.random. */
const randomUUIDForArtifact = (): string =>
  createHash("sha256").update(process.hrtime.bigint().toString()).digest("hex").slice(0, 12)

const splitRef = (source: string): readonly [string, string | undefined] => {
  const index = source.indexOf("#")
  if (index === -1) return [source, undefined]
  const ref = source.slice(index + 1)
  return [source.slice(0, index), ref === "" ? undefined : ref]
}

/// Default clone: shallow, optionally pinned to a branch or tag, with
/// interactive prompts disabled so a bad URL fails fast instead of hanging.
const cloneSkillSource = (
  url: string,
  ref: string | undefined,
  destination: string
): Promise<void> =>
  new Promise((resolvePromise, rejectPromise) => {
    const args = [
      "clone",
      "--depth",
      "1",
      ...(ref === undefined ? [] : ["--branch", ref]),
      url,
      destination
    ]
    const child = spawn("git", args, {
      env: {
        ...process.env,
        GIT_ASKPASS: "true",
        GIT_SSH_COMMAND: process.env["GIT_SSH_COMMAND"] ?? "ssh -oBatchMode=yes",
        GIT_TERMINAL_PROMPT: "0"
      }
    })
    const stderr: Array<string> = []
    child.stderr.setEncoding("utf8")
    child.stderr.on("data", (chunk: string) => stderr.push(chunk))
    /* v8 ignore next -- spawn-level failures (git missing) need an environment tests can't fake. */
    child.on("error", (cause) => rejectPromise(cause))
    child.on("close", (code) => {
      if (code === 0) {
        resolvePromise()
        return
      }
      const reason = stderr.join("").trim()
      /* v8 ignore next -- git always writes a failure reason to stderr; exit-code fallback is a backstop. */
      rejectPromise(new Error(reason === "" ? `git clone exited with ${code}` : reason))
    })
  })

/* v8 ignore next 2 -- the ?? arm is unreachable: callers validate harnessId against the catalog first. */
const definitionName = (config: SkillsManagerConfig, harnessId: string): string =>
  config.agents.catalog.find((candidate) => candidate.id === harnessId)?.name ?? harnessId

/// realpath when the path exists, the resolved-parent form when it doesn't —
/// so comparisons against not-yet-created directories still behave.
const resolveExisting = async (path: string): Promise<string> => {
  try {
    return await realpath(path)
  } catch {
    return resolveParentSymlinks(path)
  }
}
