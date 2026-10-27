import { createServerFn } from "@tanstack/react-start"

import { GITHUB_REPO_API_URL, githubRequestHeaders, parseStars } from "./github-repo"

const FRESH_MS = 60 * 60 * 1000
const KEEP_STALE_SECONDS = 30 * 24 * 60 * 60
const RETRY_AFTER_FAILURE_MS = 5 * 60 * 1000
const FETCH_TIMEOUT_MS = 2500
const CACHE_KEY = GITHUB_REPO_API_URL

interface StarCount {
  stars: number
  checkedAt: number
}

let remembered: { stars: number | null; expiresAt: number } | undefined

export const fetchGitHubStars = createServerFn({ method: "GET" }).handler(
  async (): Promise<number | null> => {
    if (remembered !== undefined && remembered.expiresAt > Date.now()) return remembered.stars

    const cache = await openCache()
    const cached = await readCachedStars(cache)
    if (cached !== null && isFresh(cached))
      return remember(cached.stars, cached.checkedAt + FRESH_MS)

    const stars = await requestStars()
    if (stars !== null) {
      await storeStars(cache, { stars, checkedAt: Date.now() })
      return remember(stars, Date.now() + FRESH_MS)
    }

    return remember(lastKnownStars(cached), Date.now() + RETRY_AFTER_FAILURE_MS)
  }
)

export const formatStars = (stars: number): string => {
  if (stars < 1000) return String(stars)
  const thousands = stars / 1000
  return `${thousands >= 10 ? Math.round(thousands) : thousands.toFixed(1).replace(/\.0$/, "")}k`
}

const remember = (stars: number | null, expiresAt: number): number | null => {
  remembered = { stars, expiresAt }
  return stars
}

const isFresh = (count: StarCount): boolean => Date.now() - count.checkedAt < FRESH_MS

const lastKnownStars = (cached: StarCount | null): number | null =>
  cached?.stars ?? remembered?.stars ?? import.meta.env.GITHUB_STARS_AT_BUILD

const openCache = async (): Promise<Cache | undefined> => {
  if (typeof caches === "undefined") return undefined
  return caches.open("github-stars").catch(() => undefined)
}

const readCachedStars = async (cache: Cache | undefined): Promise<StarCount | null> => {
  const cached = await cache?.match(CACHE_KEY).catch(() => undefined)
  if (cached === undefined) return null
  return parseStarCount(await cached.json().catch(() => null))
}

const parseStarCount = (body: unknown): StarCount | null => {
  const stars = parseStars(body)
  if (stars === null || typeof body !== "object" || body === null || !("checkedAt" in body))
    return null
  return typeof body.checkedAt === "number" ? { stars, checkedAt: body.checkedAt } : null
}

const requestStars = async (): Promise<number | null> => {
  const response = await fetch(GITHUB_REPO_API_URL, {
    headers: githubRequestHeaders(process.env.GITHUB_TOKEN),
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS)
  }).catch((error: unknown) => {
    console.warn("GitHub stars request failed", error)
    return undefined
  })
  if (response === undefined) return null
  if (!response.ok) return rejectedStars(response)
  return parseStars(await response.json().catch(() => null))
}

const rejectedStars = (response: Response): null => {
  console.warn("GitHub stars request rejected", {
    status: response.status,
    rateLimitRemaining: response.headers.get("x-ratelimit-remaining"),
    rateLimitReset: response.headers.get("x-ratelimit-reset")
  })
  return null
}

const storeStars = async (cache: Cache | undefined, count: StarCount): Promise<void> => {
  const response = Response.json(
    { stargazers_count: count.stars, checkedAt: count.checkedAt },
    { headers: { "cache-control": `public, max-age=${KEEP_STALE_SECONDS}` } }
  )
  await cache?.put(CACHE_KEY, response).catch(() => undefined)
}
