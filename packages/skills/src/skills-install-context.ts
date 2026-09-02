import type { SkillsScan } from "@codevisor/api"
import { lstat, mkdir, realpath, rename, rm, symlink } from "node:fs/promises"
import { basename, dirname, join, relative, resolve } from "node:path"
import { resolveNativeConfigPath } from "./native-paths.js"
import type { SkillsManagerConfig } from "./skills-manager.js"
import { cloneSkillSource } from "./skills-remote-source.js"
import {
  copyDirectory,
  hasSkillFile,
  isDirectory,
  isPathSafe,
  resolveExisting,
  resolveParentSymlinks,
  skillContentHash,
  SkillsError,
  type CanonicalSkill
} from "./skills-store.js"

export interface SkillsOperationsDeps {
  readonly canonicalDir: string
  readonly config: SkillsManagerConfig
  readonly env: Readonly<Record<string, string | undefined>>
  readonly home: string
  readonly isManagedSkill: (path: string) => Promise<boolean>
  readonly list: () => Promise<SkillsScan>
  readonly listCanonical: () => Promise<ReadonlyArray<CanonicalSkill>>
}

export interface HarnessSkillsDir {
  readonly dir: string
  readonly readsCanonical: boolean
  readonly alsoReadsCanonical: boolean
}

/* v8 ignore next 2 -- the ?? arm is unreachable: callers validate harnessId against the catalog first. */
export const definitionName = (config: SkillsManagerConfig, harnessId: string): string =>
  config.agents.catalog.find((candidate) => candidate.id === harnessId)?.name ?? harnessId

/// A directory name that must reference a direct child of `base`. Rejects
/// separators and traversal before any path is built from API input.
export const assertSafeChild = (base: string, name: string): string => {
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

/// Remove a filesystem entry with the iron rules applied: links are
/// removed as links (never followed, never recursive). Callers must have
/// already proven a real directory is safe to delete (inside the canonical
/// store, or hash-verified against it) before reaching this.
export const safeRemove = async (path: string): Promise<void> => {
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

/// The shared seams of every install operation: the injected filesystem
/// overrides, harness directory resolution, and the link/copy primitives
/// that put a canonical skill into a harness directory.
export const makeSkillsInstallContext = (deps: SkillsOperationsDeps) => {
  const { canonicalDir, config, env, home } = deps

  const symlinkFn = config.overrides?.symlink ?? symlink
  const renameFn = config.overrides?.rename ?? rename
  const cloneFn = config.overrides?.clone ?? cloneSkillSource

  const harnessSkillsDir = (harnessId: string): HarnessSkillsDir => {
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

  return {
    ...deps,
    canonicalSkillPath,
    cloneFn,
    createSkillLink,
    harnessSkillsDir,
    installEverywhere,
    installIntoDir,
    renameFn
  }
}

export type SkillsInstallContext = ReturnType<typeof makeSkillsInstallContext>
