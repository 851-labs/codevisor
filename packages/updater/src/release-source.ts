import { createHash } from "node:crypto"
import { createReadStream } from "node:fs"

import { isNewerVersion } from "./harness-update-sources.js"
import { jsonField, jsonString } from "./json-fields.js"

export const DEFAULT_GITHUB_REPOSITORY = "851-labs/codevisor"
export const DEFAULT_STABLE_SERVER_MANIFEST_URL = "https://updates.codevisor.dev/server/stable.json"
export const DEFAULT_ALPHA_SERVER_MANIFEST_URL = "https://updates.codevisor.dev/server/alpha.json"
export const DEFAULT_LEGACY_RELEASE_BASE_URL =
  "https://pub-d2d6eb72b71c4986a742c0527774c9f0.r2.dev/releases/codevisor"

export type ServerUpdateChannel = "stable" | "alpha"

export type ServerRelease = {
  readonly version: string
  readonly buildNumber?: number | undefined
  readonly archiveURL: string
  readonly checksumURL?: string | undefined
  readonly releasePageURL?: string | undefined
}

export const isNewerRelease = (
  candidate: Pick<ServerRelease, "version" | "buildNumber">,
  current: { readonly version: string; readonly buildNumber?: number | undefined }
): boolean =>
  candidate.buildNumber !== undefined && current.buildNumber !== undefined
    ? candidate.buildNumber > current.buildNumber
    : isNewerVersion(candidate.version, current.version)

const isArray = (value: unknown): value is ReadonlyArray<unknown> => Array.isArray(value)

const normalizedVersion = (value: unknown): string =>
  typeof value === "string" ? value.replace(/^v/, "").trim() : ""

export const serverReleaseFromGitHub = (
  body: unknown,
  target: string
): ServerRelease | undefined => {
  if (jsonField(body, "draft") === true || jsonField(body, "prerelease") === true) {
    return undefined
  }
  const version = normalizedVersion(jsonField(body, "tag_name"))
  const assets = jsonField(body, "assets")
  if (version.length === 0 || !isArray(assets)) {
    return undefined
  }
  const archiveName = `codevisor-server-${target}.tar.gz`
  const assetURL = (name: string): string | undefined =>
    jsonString(
      assets.find((candidate) => jsonField(candidate, "name") === name),
      "browser_download_url"
    )
  const archiveURL = assetURL(archiveName)
  if (archiveURL === undefined) {
    return undefined
  }
  return {
    version,
    archiveURL,
    checksumURL: assetURL(`${archiveName}.sha256`),
    releasePageURL: jsonString(body, "html_url")
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
  return serverReleaseFromGitHub(await response.json(), options.target)
}

export const serverReleaseFromManifest = (
  body: unknown,
  target: string
): ServerRelease | undefined => {
  const version = normalizedVersion(jsonField(body, "version"))
  const candidate = jsonField(jsonField(body, "targets"), target)
  const archiveURL = jsonString(candidate, "archiveURL")
  if (version.length === 0 || archiveURL === undefined) {
    return undefined
  }
  const buildNumber = jsonField(body, "buildNumber")
  return {
    version,
    buildNumber:
      typeof buildNumber === "number" && Number.isSafeInteger(buildNumber)
        ? buildNumber
        : undefined,
    archiveURL,
    checksumURL: jsonString(candidate, "checksumURL"),
    releasePageURL: jsonString(body, "releasePageURL")
  }
}

export const fetchStableServerRelease = async (options: {
  readonly target: string
  readonly fetch?: typeof globalThis.fetch | undefined
}): Promise<ServerRelease | undefined> => {
  const fetcher = options.fetch ?? globalThis.fetch
  const response = await fetcher(DEFAULT_STABLE_SERVER_MANIFEST_URL, {
    headers: { "cache-control": "no-cache" },
    signal: AbortSignal.timeout(10_000)
  })
  if (!response.ok) {
    throw new Error(`Stable server manifest lookup failed: HTTP ${response.status}`)
  }
  return serverReleaseFromManifest(await response.json(), options.target)
}

export const fetchAlphaServerRelease = async (options: {
  readonly target: string
  readonly fetch?: typeof globalThis.fetch | undefined
}): Promise<ServerRelease | undefined> => {
  const fetcher = options.fetch ?? globalThis.fetch
  const response = await fetcher(DEFAULT_ALPHA_SERVER_MANIFEST_URL, {
    headers: { "cache-control": "no-cache" },
    signal: AbortSignal.timeout(10_000)
  })
  if (!response.ok) {
    throw new Error(`Alpha server manifest lookup failed: HTTP ${response.status}`)
  }
  return serverReleaseFromManifest(await response.json(), options.target)
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
  const version = normalizedVersion(jsonField(await response.json(), "version"))
  if (version.length === 0) {
    return undefined
  }
  const archiveURL = `${options.baseURL}/v${version}/codevisor-server-${options.target}.tar.gz`
  return { version, archiveURL, checksumURL: `${archiveURL}.sha256` }
}

export const fetchLatestServerRelease = async (options: {
  readonly channel?: ServerUpdateChannel | undefined
  readonly repository: string
  readonly legacyBaseURL: string
  readonly target: string
  readonly fetch?: typeof globalThis.fetch | undefined
}): Promise<ServerRelease | undefined> => {
  const alphaRelease =
    options.channel === "alpha"
      ? await fetchAlphaServerRelease({
          target: options.target,
          fetch: options.fetch
        }).catch(() => undefined)
      : undefined
  try {
    const release = await fetchStableServerRelease({
      target: options.target,
      fetch: options.fetch
    })
    if (release !== undefined) {
      return alphaRelease !== undefined && isNewerRelease(alphaRelease, release)
        ? alphaRelease
        : release
    }
  } catch {}
  if (alphaRelease !== undefined) return alphaRelease
  try {
    const release = await fetchLatestGitHubServerRelease({
      repository: options.repository,
      target: options.target,
      fetch: options.fetch
    })
    if (release !== undefined) return release
  } catch {}
  return fetchLegacyServerRelease({
    baseURL: options.legacyBaseURL,
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
