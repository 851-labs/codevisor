import { realpathSync } from "node:fs"

import type { InstallOrigin } from "@codevisor/agent-runtime"

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

export { isNewerVersion } from "./version-comparison.js"

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

export const checkPypiLatest = async (
  packageName: string,
  fetchImpl: FetchLike = fetch
): Promise<LatestVersionResult> => {
  try {
    const document = (await fetchJson(
      fetchImpl,
      `https://pypi.org/pypi/${encodeURIComponent(packageName)}/json`
    )) as { readonly info?: { readonly version?: string } }
    const version = document.info?.version
    return typeof version === "string" && version.length > 0
      ? { channel: "stable", latestVersion: version }
      : none
  } catch {
    return none
  }
}

export const checkBrewLatest = async (
  formula: string,
  fetchImpl: FetchLike = fetch
): Promise<LatestVersionResult> => {
  try {
    const document = (await fetchJson(
      fetchImpl,
      `https://formulae.brew.sh/api/formula/${encodeURIComponent(formula)}.json`
    )) as { readonly versions?: { readonly stable?: string } }
    const stable = document.versions?.stable
    if (typeof stable === "string" && stable.length > 0) {
      return { channel: "stable", latestVersion: stable }
    }
  } catch {}
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
    const version = (document.tag_name ?? "").replace(/^[^0-9]*/, "")
    return version.length > 0 ? { channel: "stable", latestVersion: version } : none
  } catch {
    return none
  }
}

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
  if (/\/uv\/tools\/[^/]+\//.test(real)) return "uv"
  if (real.includes("/node_modules/")) return "npm"
  if (real.includes("/Cellar/") || real.includes("/Caskroom/") || real.includes("/homebrew/")) {
    return "brew"
  }
  if (/\.app\//.test(real)) return "appBundle"
  const home = options.home ?? process.env.HOME ?? ""
  if (home.length > 0 && real.startsWith(`${home}/`)) {
    return /\/\.[^/]+\//.test(real.slice(home.length)) ? "curl" : "standalone"
  }
  if (real.startsWith("/usr/local/bin/") || real.startsWith("/usr/bin/")) return "standalone"
  return "unknown"
}

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
