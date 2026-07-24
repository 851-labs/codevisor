import type { InstallOrigin } from "@codevisor/agent-runtime"
import { realpathSync } from "node:fs"

/// Pure latest-version checkers for harness update detection: npm registry,
/// Homebrew API, GitHub releases. All of them degrade to `undefined` on any
/// failure (offline, rate limit, unknown package) — an update check must
/// never surface an error to the user, only silence.

export interface LatestVersionResult {
  readonly latestVersion?: string
  readonly channel?: string
}

export interface BrewPackage {
  readonly formula: string
  readonly cask: boolean
}

const none: LatestVersionResult = {}

export type FetchLike = (
  url: string,
  init?: { readonly headers?: Record<string, string>; readonly signal?: AbortSignal }
) => Promise<{
  readonly ok: boolean
  readonly status: number
  readonly json: () => Promise<unknown>
  readonly text: () => Promise<string>
}>

const CHECK_TIMEOUT_MS = 10_000

/// Semver-style version comparison, tolerant of `v` prefixes and build
/// metadata. Numeric cores compare first; on equal cores a release outranks
/// any pre-release (`0.1.94` > `0.1.94-rc.37` — an rc/alpha install must
/// still be offered its own stable), and pre-releases compare
/// identifier-by-identifier per semver §11. Lifted from the server
/// self-updater so both share one notion of "newer".
export const isNewerVersion = (candidate: string, current: string): boolean => {
  const left = parseVersion(candidate)
  const right = parseVersion(current)
  for (let index = 0; index < Math.max(left.core.length, right.core.length); index += 1) {
    const a = left.core[index] ?? 0
    const b = right.core[index] ?? 0
    if (a !== b) {
      return a > b
    }
  }
  return comparePrerelease(left.prerelease, right.prerelease) > 0
}

const parseVersion = (
  version: string
): { readonly core: ReadonlyArray<number>; readonly prerelease: ReadonlyArray<string> } => {
  /* v8 ignore next -- split() always yields a first element; ?? guards the type. */
  const normalized = version.trim().replace(/^v/, "").split("+")[0] ?? ""
  const dash = normalized.indexOf("-")
  const core = dash === -1 ? normalized : normalized.slice(0, dash)
  return {
    core: core.split(".").map((part) => Number(part) || 0),
    prerelease: dash === -1 ? [] : normalized.slice(dash + 1).split(".")
  }
}

const comparePrerelease = (left: ReadonlyArray<string>, right: ReadonlyArray<string>): number => {
  // A release outranks any pre-release of the same core.
  if (left.length === 0 || right.length === 0) {
    return left.length === right.length ? 0 : left.length === 0 ? 1 : -1
  }
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const a = left[index]
    const b = right[index]
    // The longer identifier list wins once the shared prefix ties.
    if (a === undefined || b === undefined) return a === undefined ? -1 : 1
    const aNumeric = /^\d+$/.test(a) ? Number(a) : undefined
    const bNumeric = /^\d+$/.test(b) ? Number(b) : undefined
    if (aNumeric !== undefined && bNumeric !== undefined) {
      if (aNumeric !== bNumeric) return aNumeric > bNumeric ? 1 : -1
    } else if (aNumeric !== undefined || bNumeric !== undefined) {
      // Numeric identifiers rank below alphanumeric ones.
      return aNumeric !== undefined ? -1 : 1
    } else if (a !== b) {
      return a > b ? 1 : -1
    }
  }
  return 0
}

const fetchJson = async (fetchImpl: FetchLike, url: string): Promise<unknown> => {
  const response = await fetchImpl(url, {
    headers: { accept: "application/json" },
    signal: AbortSignal.timeout(CHECK_TIMEOUT_MS)
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return response.json()
}

export const checkNpmLatest = async (
  packageName: string,
  distTag = "latest",
  fetchImpl: FetchLike = fetch
): Promise<LatestVersionResult> => {
  try {
    // The abbreviated registry document is a fraction of the full metadata.
    // Package names (incl. @scope/name) are registry-URL-safe as-is.
    const response = await fetchImpl(`https://registry.npmjs.org/${packageName}`, {
      headers: { accept: "application/vnd.npm.install-v1+json" },
      signal: AbortSignal.timeout(CHECK_TIMEOUT_MS)
    })
    if (!response.ok) return none
    const document = (await response.json()) as {
      readonly "dist-tags"?: Record<string, string>
    }
    const version = document["dist-tags"]?.[distTag]
    return typeof version === "string" && version.length > 0
      ? { channel: distTag, latestVersion: version }
      : none
  } catch {
    return none
  }
}

export const checkBrewLatest = async (
  formula: string,
  fetchImpl: FetchLike = fetch
): Promise<LatestVersionResult> => {
  // Try the formula API first, then the cask API — catalog entries only name
  // the token and some CLIs (codex) ship as casks.
  try {
    const document = (await fetchJson(
      fetchImpl,
      `https://formulae.brew.sh/api/formula/${encodeURIComponent(formula)}.json`
    )) as { readonly versions?: { readonly stable?: string } }
    const stable = document.versions?.stable
    if (typeof stable === "string" && stable.length > 0) {
      return { channel: "stable", latestVersion: stable }
    }
  } catch {
    // Fall through to the cask API.
  }
  try {
    const document = (await fetchJson(
      fetchImpl,
      `https://formulae.brew.sh/api/cask/${encodeURIComponent(formula)}.json`
    )) as { readonly version?: string }
    return typeof document.version === "string" && document.version.length > 0
      ? { channel: "stable", latestVersion: document.version }
      : none
  } catch {
    return none
  }
}

export const checkGithubLatest = async (
  repo: string,
  fetchImpl: FetchLike = fetch
): Promise<LatestVersionResult> => {
  try {
    const document = (await fetchJson(
      fetchImpl,
      `https://api.github.com/repos/${repo}/releases/latest`
    )) as { readonly tag_name?: string }
    // Tags come prefixed in the wild: "v1.2.3", "rust-v0.4.0", "cli-2.0".
    const version = (document.tag_name ?? "").replace(/^[^0-9]*/, "")
    return version.length > 0 ? { channel: "stable", latestVersion: version } : none
  } catch {
    return none
  }
}

/// Classifies how a detected harness binary got installed, from its resolved
/// path. Symlinks are resolved first: npm globals on a brew-installed node
/// live at /opt/homebrew/bin/<cli> → /opt/homebrew/lib/node_modules/…, so the
/// node_modules check must run on the real path and win over the brew prefix.
export const detectInstallOrigin = (
  binaryPath: string,
  options: {
    readonly home?: string
    readonly realpath?: (path: string) => string
  } = {}
): InstallOrigin => {
  const resolve = options.realpath ?? ((path: string) => realpathSync(path))
  let real: string
  try {
    real = resolve(binaryPath)
  } catch {
    real = binaryPath
  }
  if (real.includes("/node_modules/")) return "npm"
  if (real.includes("/Cellar/") || real.includes("/Caskroom/") || real.includes("/homebrew/")) {
    return "brew"
  }
  if (/\.app\//.test(real)) return "appBundle"
  const home = options.home ?? process.env.HOME ?? ""
  if (home.length > 0 && real.startsWith(`${home}/`)) {
    // Vendor curl installers land in home-dot directories: ~/.local/bin,
    // ~/.opencode/bin, ~/.kilo/bin, ~/.factory/bin, ~/.codex/packages/… .
    // The standalone/self-managed distinction doesn't change which update
    // source matches, so home installs all classify as curl.
    return /\/\.[^/]+\//.test(real.slice(home.length)) ? "curl" : "standalone"
  }
  if (real.startsWith("/usr/local/bin/") || real.startsWith("/usr/bin/")) return "standalone"
  return "unknown"
}

/// Identifies the exact Homebrew owner of a resolved binary. The token comes
/// from the Cellar/Caskroom path rather than the harness catalog so versioned
/// channels such as `claude-code@latest` are preserved during updates.
export const detectBrewPackage = (
  binaryPath: string,
  options: { readonly realpath?: (path: string) => string } = {}
): BrewPackage | undefined => {
  const resolve = options.realpath ?? ((path: string) => realpathSync(path))
  let real: string
  try {
    real = resolve(binaryPath)
  } catch {
    real = binaryPath
  }
  const match = real.match(/\/(Cellar|Caskroom)\/([A-Za-z0-9@+_.-]+)\//)
  const location = match?.[1]
  const formula = match?.[2]
  return location === undefined || formula === undefined
    ? undefined
    : { cask: location === "Caskroom", formula }
}
