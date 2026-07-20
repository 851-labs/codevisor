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

/// Dotted-numeric version comparison, tolerant of `v` prefixes and
/// pre-release suffixes (compares the numeric core only). Lifted from the
/// server self-updater so both share one notion of "newer".
export const isNewerVersion = (candidate: string, current: string): boolean => {
  const parse = (version: string): ReadonlyArray<number> => {
    /* v8 ignore next -- split() always yields a first element; ?? guards the type. */
    const core = version.replace(/^v/, "").split("-")[0] ?? ""
    return core.split(".").map((part) => Number(part) || 0)
  }
  const left = parse(candidate)
  const right = parse(current)
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const a = left[index] ?? 0
    const b = right[index] ?? 0
    if (a !== b) {
      return a > b
    }
  }
  return false
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
