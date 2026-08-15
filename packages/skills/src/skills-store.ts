import { createHash } from "node:crypto"
import { chmod, cp, mkdir, readdir, readFile, realpath, stat } from "node:fs/promises"
import { basename, dirname, join, normalize, resolve, sep } from "node:path"
import { parse as parseYaml } from "yaml"

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

export const CANONICAL_SKILLS_DIR = "~/.agents/skills"
export const MANAGED_SKILL_MARKER = ".codevisor-managed-skill"
export const MANAGED_SKILL_MARKER_CONTENT = "codevisor-managed-skill-v1\n"

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

export const resolveSymlinkTarget = (linkPath: string, linkTarget: string): string =>
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

export const EXCLUDE_FILES: ReadonlySet<string> = new Set(["metadata.json"])
export const EXCLUDE_DIRS: ReadonlySet<string> = new Set([".git", "__pycache__", "__pypackages__"])

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

export const isDirectory = async (path: string): Promise<boolean> => {
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

export interface SkillDocument {
  readonly name: string
  readonly description: string | undefined
  readonly invalid: boolean
}

/// Parse SKILL.md tolerantly: malformed frontmatter degrades to the directory
/// name plus an `invalid` badge, never a scan failure.
export const readSkillDocument = async (
  dir: string,
  directoryName: string
): Promise<SkillDocument> => {
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

export const hasSkillFile = async (dir: string): Promise<boolean> => {
  try {
    return (await stat(join(dir, "SKILL.md"))).isFile()
  } catch {
    return false
  }
}

export interface CanonicalSkill {
  readonly directoryName: string
  readonly path: string
  readonly document: SkillDocument
  readonly hash: string
}

export interface HarnessEntry {
  readonly directoryName: string
  readonly path: string
  readonly kind: "linkedTo" | "independent" | "broken"
  /// For `linkedTo`: the canonical directory name the link resolves to.
  readonly linkTarget?: string
  readonly hash?: string
  readonly document?: SkillDocument
}

/// realpath when the path exists, the resolved-parent form when it doesn't —
/// so comparisons against not-yet-created directories still behave.
export const resolveExisting = async (path: string): Promise<string> => {
  try {
    return await realpath(path)
  } catch {
    return resolveParentSymlinks(path)
  }
}
