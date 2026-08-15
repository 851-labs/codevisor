import type { SkillsScan } from "@codevisor/api"
import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import { rename, symlink } from "node:fs/promises"
import { homedir } from "node:os"
import { resolveNativeConfigPath } from "./native-paths.js"
import { makeSkillsOperations } from "./skills-install.js"
import { makeSkillsScanner } from "./skills-scan.js"
import { CANONICAL_SKILLS_DIR } from "./skills-store.js"

export {
  CANONICAL_SKILLS_DIR,
  copyDirectory,
  isPathSafe,
  parseFrontmatter,
  pathsOverlap,
  resolveParentSymlinks,
  sanitizeName,
  skillContentHash,
  SkillsError
} from "./skills-store.js"
export { parseSkillSource, type ParsedSkillSource } from "./skills-remote-source.js"

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
  /// Install, update, or remove app-owned skills without surfacing them as
  /// user-managed entries. The marker prevents Codevisor from overwriting a
  /// same-name skill it does not own.
  readonly syncManaged: (skills: ReadonlyArray<ManagedSkillSpec>) => Promise<void>
}

export interface ManagedSkillSpec {
  readonly directoryName: string
  readonly sourcePath: string
  readonly enabled: boolean
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

export const makeSkillsManager = (config: SkillsManagerConfig): SkillsManager => {
  const home = config.homedir ?? homedir()
  const env = config.env ?? process.env

  const canonicalDir = resolveNativeConfigPath(CANONICAL_SKILLS_DIR, { env, home })

  const { isManagedSkill, list, listCanonical } = makeSkillsScanner({
    canonicalDir,
    config,
    env,
    home
  })

  return {
    list,
    ...makeSkillsOperations({
      canonicalDir,
      config,
      env,
      home,
      isManagedSkill,
      list,
      listCanonical
    })
  }
}
