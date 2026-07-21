import { createHash } from "node:crypto"
import { createReadStream } from "node:fs"

export const DEFAULT_GITHUB_REPOSITORY = "851-labs/codevisor"
export const DEFAULT_LEGACY_RELEASE_BASE_URL =
  "https://pub-d2d6eb72b71c4986a742c0527774c9f0.r2.dev/releases/codevisor"

export type ServerRelease = {
  readonly version: string
  readonly archiveURL: string
  readonly checksumURL?: string | undefined
  readonly releasePageURL?: string | undefined
}

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

/// GitHub is authoritative. The frozen bucket is consulted only when GitHub
/// itself is unavailable or rate-limited, never to outrank a valid response.
export const fetchLatestServerRelease = async (options: {
  readonly repository?: string
  readonly legacyBaseURL?: string
  readonly target: string
  readonly fetch?: typeof globalThis.fetch | undefined
}): Promise<ServerRelease | undefined> => {
  try {
    return await fetchLatestGitHubServerRelease({
      repository: options.repository ?? DEFAULT_GITHUB_REPOSITORY,
      target: options.target,
      fetch: options.fetch
    })
  } catch {
    return fetchLegacyServerRelease({
      baseURL: options.legacyBaseURL ?? DEFAULT_LEGACY_RELEASE_BASE_URL,
      target: options.target,
      fetch: options.fetch
    })
  }
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
