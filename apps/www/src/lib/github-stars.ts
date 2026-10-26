import { createServerFn } from "@tanstack/react-start"

export const GITHUB_REPO_URL = "https://github.com/851-labs/codevisor"

const REPO_API_URL = "https://api.github.com/repos/851-labs/codevisor"
const CACHE_SECONDS = 60 * 60
const RETRY_AFTER_FAILURE_MS = 5 * 60 * 1000
const FETCH_TIMEOUT_MS = 2500

let remembered: { stars: number | null; expiresAt: number } | undefined

const parseStars = (body: unknown): number | null => {
  if (typeof body !== "object" || body === null || !("stargazers_count" in body)) return null
  const stars = body.stargazers_count
  return typeof stars === "number" ? stars : null
}

const readCachedStars = async (cache: Cache): Promise<number | null> => {
  const cached = await cache.match(REPO_API_URL)
  if (cached === undefined) return null
  return parseStars(await cached.json())
}

const requestStars = async (): Promise<number | null> => {
  const response = await fetch(REPO_API_URL, {
    headers: { accept: "application/vnd.github+json", "user-agent": "codevisor-www" },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS)
  })
  if (!response.ok) return null
  return parseStars(await response.json())
}

const storeStars = (cache: Cache, stars: number): Promise<void> =>
  cache.put(
    REPO_API_URL,
    Response.json(
      { stargazers_count: stars },
      { headers: { "cache-control": `public, max-age=${CACHE_SECONDS}` } }
    )
  )

const loadStars = async (): Promise<number | null> => {
  if (typeof caches === "undefined") return requestStars()
  const cache = await caches.open("github-stars")
  const cachedStars = await readCachedStars(cache)
  if (cachedStars !== null) return cachedStars
  const stars = await requestStars()
  if (stars !== null) await storeStars(cache, stars)
  return stars
}

export const fetchGitHubStars = createServerFn({ method: "GET" }).handler(
  async (): Promise<number | null> => {
    if (remembered !== undefined && remembered.expiresAt > Date.now()) return remembered.stars
    const stars = await loadStars().catch(() => null)
    if (stars === null) {
      const lastKnown = remembered?.stars ?? null
      remembered = { stars: lastKnown, expiresAt: Date.now() + RETRY_AFTER_FAILURE_MS }
      return lastKnown
    }
    remembered = { stars, expiresAt: Date.now() + CACHE_SECONDS * 1000 }
    return stars
  }
)

export const formatStars = (stars: number): string => {
  if (stars < 1000) return String(stars)
  const thousands = stars / 1000
  return `${thousands >= 10 ? Math.round(thousands) : thousands.toFixed(1).replace(/\.0$/, "")}k`
}
