import { createHash } from "node:crypto"
import { createReadStream } from "node:fs"
import { isNewerVersion } from "./harness-update-sources.js"

export const DEFAULT_GITHUB_REPOSITORY = "851-labs/codevisor"
export const DEFAULT_STABLE_SERVER_MANIFEST_URL = "https://updates.codevisor.dev/server/stable.json"
export const DEFAULT_ALPHA_SERVER_MANIFEST_URL = "https://updates.codevisor.dev/server/alpha.json"
export const DEFAULT_LEGACY_RELEASE_BASE_URL =
  "https://pub-d2d6eb72b71c4986a742c0527774c9f0.r2.dev/releases/codevisor"

/// Server update channels. `alpha` sees alpha AND stable releases (newest
/// wins); `stable` sees stable only.
export type ServerUpdateChannel = "stable" | "alpha"

export type ServerRelease = {
  readonly version: string
  /// CI run number stamped into every build (matches the runtime's
  /// BUILD.json and the Sparkle `sparkle:version`). Monotonic across all
  /// releases, unlike version strings — successive alphas share a core
  /// version, so channel comparisons prefer this when both sides have one.
  readonly buildNumber?: number | undefined
  readonly archiveURL: string
  readonly checksumURL?: string | undefined
  readonly releasePageURL?: string | undefined
}

/// Whether `candidate` is a newer release than the installed
/// (version, buildNumber) pair: build numbers when both are known,
/// falling back to semver-style version comparison.
export const isNewerRelease = (
  candidate: Pick<ServerRelease, "version" | "buildNumber">,
  current: { readonly version: string; readonly buildNumber?: number | undefined }
): boolean =>
  candidate.buildNumber !== undefined && current.buildNumber !== undefined
    ? candidate.buildNumber > current.buildNumber
    : isNewerVersion(candidate.version, current.version)

type GitHubReleaseResponse = {
  readonly tag_name?: unknown
  readonly html_url?: unknown
  readonly draft?: unknown
  readonly prerelease?: unknown
  readonly assets?: ReadonlyArray<{
    readonly name?: unknown
    readonly browser_download_url?: unknown
  }>
}

type ServerManifest = {
  readonly version?: unknown
  readonly buildNumber?: unknown
  readonly releasePageURL?: unknown
  readonly targets?: Record<
    string,
    {
      readonly archiveURL?: unknown
      readonly checksumURL?: unknown
    }
  >
}

const normalizedVersion = (value: unknown): string =>
  typeof value === "string" ? value.replace(/^v/, "").trim() : ""

export const serverReleaseFromGitHub = (
  body: GitHubReleaseResponse,
  target: string
): ServerRelease | undefined => {
  if (body.draft === true || body.prerelease === true) {
    return undefined
  }
  const version = normalizedVersion(body.tag_name)
  if (version.length === 0 || !Array.isArray(body.assets)) {
    return undefined
  }
  const archiveName = `codevisor-server-${target}.tar.gz`
  const assetURL = (name: string): string | undefined => {
    const asset = body.assets?.find((candidate) => candidate.name === name)
    return typeof asset?.browser_download_url === "string" ? asset.browser_download_url : undefined
  }
  const archiveURL = assetURL(archiveName)
  if (archiveURL === undefined) {
    return undefined
  }
  return {
    version,
    archiveURL,
    checksumURL: assetURL(`${archiveName}.sha256`),
    releasePageURL: typeof body.html_url === "string" ? body.html_url : undefined
  }
}

export const fetchLatestGitHubServerRelease = async (options: {
  readonly repository: string
  readonly target: string
  readonly fetch?: typeof globalThis.fetch | undefined
}): Promise<ServerRelease | undefined> => {
  const fetcher = options.fetch ?? globalThis.fetch
  const response = await fetcher(
    `https://api.github.com/repos/${options.repository}/releases/latest`,
    {
      headers: {
        Accept: "application/vnd.github+json",
        "User-Agent": "Codevisor-Server-Updater",
        "X-GitHub-Api-Version": "2022-11-28"
      },
      signal: AbortSignal.timeout(10_000)
    }
  )
  if (!response.ok) {
    throw new Error(`GitHub release lookup failed: HTTP ${response.status}`)
  }
  return serverReleaseFromGitHub((await response.json()) as GitHubReleaseResponse, options.target)
}

export const serverReleaseFromManifest = (
  body: ServerManifest,
  target: string
): ServerRelease | undefined => {
  const version = normalizedVersion(body.version)
  const candidate = body.targets?.[target]
  if (version.length === 0 || typeof candidate?.archiveURL !== "string") {
    return undefined
  }
  return {
    version,
    buildNumber:
      typeof body.buildNumber === "number" && Number.isSafeInteger(body.buildNumber)
        ? body.buildNumber
        : undefined,
    archiveURL: candidate.archiveURL,
    checksumURL: typeof candidate.checksumURL === "string" ? candidate.checksumURL : undefined,
    releasePageURL: typeof body.releasePageURL === "string" ? body.releasePageURL : undefined
  }
}

export const fetchStableServerRelease = async (options: {
  readonly manifestURL?: string | undefined
  readonly target: string
  readonly fetch?: typeof globalThis.fetch | undefined
}): Promise<ServerRelease | undefined> => {
  const fetcher = options.fetch ?? globalThis.fetch
  const response = await fetcher(options.manifestURL ?? DEFAULT_STABLE_SERVER_MANIFEST_URL, {
    headers: { "cache-control": "no-cache" },
    signal: AbortSignal.timeout(10_000)
  })
  if (!response.ok) {
    throw new Error(`Stable server manifest lookup failed: HTTP ${response.status}`)
  }
  return serverReleaseFromManifest((await response.json()) as ServerManifest, options.target)
}

export const fetchAlphaServerRelease = async (options: {
  readonly manifestURL?: string | undefined
  readonly target: string
  readonly fetch?: typeof globalThis.fetch | undefined
}): Promise<ServerRelease | undefined> => {
  const fetcher = options.fetch ?? globalThis.fetch
  const response = await fetcher(options.manifestURL ?? DEFAULT_ALPHA_SERVER_MANIFEST_URL, {
    headers: { "cache-control": "no-cache" },
    signal: AbortSignal.timeout(10_000)
  })
  if (!response.ok) {
    throw new Error(`Alpha server manifest lookup failed: HTTP ${response.status}`)
  }
  return serverReleaseFromManifest((await response.json()) as ServerManifest, options.target)
}

export const fetchLegacyServerRelease = async (options: {
  readonly baseURL: string
  readonly target: string
  readonly fetch?: typeof globalThis.fetch | undefined
}): Promise<ServerRelease | undefined> => {
  const fetcher = options.fetch ?? globalThis.fetch
  const response = await fetcher(`${options.baseURL}/latest.json`, {
    headers: { "cache-control": "no-cache" },
    signal: AbortSignal.timeout(10_000)
  })
  if (!response.ok) {
    return undefined
  }
  const version = normalizedVersion(
    ((await response.json()) as { readonly version?: unknown }).version
  )
  if (version.length === 0) {
    return undefined
  }
  const archiveURL = `${options.baseURL}/v${version}/codevisor-server-${options.target}.tar.gz`
  return { version, archiveURL, checksumURL: `${archiveURL}.sha256` }
}

/// The first-party stable manifest is authoritative and avoids coupling Linux
/// updates to GitHub's mutable "latest release" pointer. GitHub and the frozen
/// bridge remain read-only fallbacks for installations crossing the cutover.
/// On the alpha channel, the alpha manifest joins the stable one and the
/// newest of the two wins — a stable cut after the last alpha must still be
/// offered to alpha followers.
export const fetchLatestServerRelease = async (options: {
  readonly channel?: ServerUpdateChannel | undefined
  readonly manifestURL?: string | undefined
  readonly alphaManifestURL?: string | undefined
  readonly repository?: string
  readonly legacyBaseURL?: string
  readonly target: string
  readonly fetch?: typeof globalThis.fetch | undefined
}): Promise<ServerRelease | undefined> => {
  const alphaRelease =
    options.channel === "alpha"
      ? await fetchAlphaServerRelease({
          manifestURL: options.alphaManifestURL,
          target: options.target,
          fetch: options.fetch
        }).catch(() => undefined)
      : undefined
  try {
    const release = await fetchStableServerRelease({
      manifestURL: options.manifestURL,
      target: options.target,
      fetch: options.fetch
    })
    if (release !== undefined) {
      return alphaRelease !== undefined && isNewerRelease(alphaRelease, release)
        ? alphaRelease
        : release
    }
  } catch {
    // Continue through the migration fallbacks.
  }
  if (alphaRelease !== undefined) return alphaRelease
  try {
    const release = await fetchLatestGitHubServerRelease({
      repository: options.repository ?? DEFAULT_GITHUB_REPOSITORY,
      target: options.target,
      fetch: options.fetch
    })
    if (release !== undefined) return release
  } catch {
    // Continue to the immutable compatibility bridge.
  }
  return fetchLegacyServerRelease({
    baseURL: options.legacyBaseURL ?? DEFAULT_LEGACY_RELEASE_BASE_URL,
    target: options.target,
    fetch: options.fetch
  })
}

export const parseSha256 = (body: string): string | undefined => {
  const match = body.trim().match(/^([a-fA-F0-9]{64})(?:\s|$)/)
  return match?.[1]?.toLowerCase()
}

export const sha256File = (path: string): Promise<string> =>
  new Promise((resolve, reject) => {
    const hash = createHash("sha256")
    const stream = createReadStream(path)
    stream.once("error", reject)
    stream.on("data", (chunk) => hash.update(chunk))
    stream.once("end", () => resolve(hash.digest("hex")))
  })
