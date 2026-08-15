import type { SkillsScan } from "@codevisor/api"
import {
  lstat,
  mkdir,
  mkdtemp,
  readdir,
  readlink,
  realpath,
  rename,
  rm,
  symlink,
  writeFile
} from "node:fs/promises"
import { tmpdir } from "node:os"
import { basename, dirname, join, relative, resolve } from "node:path"
import { resolveNativeConfigPath } from "./native-paths.js"
import type { ManagedSkillSpec, SkillsManagerConfig } from "./skills-manager.js"
import {
  cloneSkillSource,
  materializeWellKnownSkills,
  parseSkillSource
} from "./skills-remote-source.js"
import {
  copyDirectory,
  EXCLUDE_DIRS,
  hasSkillFile,
  isDirectory,
  isPathSafe,
  MANAGED_SKILL_MARKER,
  MANAGED_SKILL_MARKER_CONTENT,
  parseFrontmatter,
  pathsOverlap,
  readSkillDocument,
  resolveExisting,
  resolveParentSymlinks,
  resolveSymlinkTarget,
  sanitizeName,
  skillContentHash,
  SkillsError,
  type CanonicalSkill
} from "./skills-store.js"

/* v8 ignore next 2 -- the ?? arm is unreachable: callers validate harnessId against the catalog first. */
const definitionName = (config: SkillsManagerConfig, harnessId: string): string =>
  config.agents.catalog.find((candidate) => candidate.id === harnessId)?.name ?? harnessId

export interface SkillsOperationsDeps {
  readonly canonicalDir: string
  readonly config: SkillsManagerConfig
  readonly env: Readonly<Record<string, string | undefined>>
  readonly home: string
  readonly isManagedSkill: (path: string) => Promise<boolean>
  readonly list: () => Promise<SkillsScan>
  readonly listCanonical: () => Promise<ReadonlyArray<CanonicalSkill>>
}

export const makeSkillsOperations = (deps: SkillsOperationsDeps) => {
  const { canonicalDir, config, env, home, isManagedSkill, list, listCanonical } = deps

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

  return {
    create,
    discoverRemote,
    importLocal,
    importRemote,
    makeGlobal,
    remove,
    setInstalled,
    sync,
    syncManaged
  }
}
