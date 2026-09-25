import type { ProjectRecommendation } from "@codevisor/api"

import { recommendProjectsFromSessions } from "../project-recommendations.js"
import { run, type CodevisorServerServices } from "../server-context.js"
import { discoverHarnesses } from "./harnesses.js"

/// The most recommendations any request may ask for; the cache holds this
/// many and each request takes its own prefix.
const maxLimit = 50

/// A cached answer younger than this is served without a rescan.
const freshForMs = 15_000

const caches = new WeakMap<
  CodevisorServerServices,
  () => Promise<ReadonlyArray<ProjectRecommendation>>
>()

const scan = async (
  services: CodevisorServerServices
): Promise<ReadonlyArray<ProjectRecommendation>> => {
  const harnesses = await discoverHarnesses(services)
  const sessionGroups = await Promise.all(
    harnesses
      .filter((harness) => harness.enabled && harness.readiness.state === "ready")
      .map(async (harness) => {
        try {
          const account = await services.auth?.activeAccountContext(harness.id)
          // Suggestions need only each session's cwd and activity time, so
          // skip the harness title lookups.
          return await run(
            services.agents.listAgentSessions(harness.id, account, { titles: false })
          )
        } catch {
          // One unavailable/corrupt harness store must not hide useful
          // recommendations from every other installed harness.
          return []
        }
      })
  )
  return recommendProjectsFromSessions(sessionGroups.flat(), { limit: maxLimit })
}

/// Stale-while-revalidate: the add-project sheet opens often and the scan
/// walks every harness store, so a cached answer is returned immediately
/// and refreshed in the background once it is no longer fresh.
export const makeStaleWhileRevalidate = <T>(
  load: () => Promise<ReadonlyArray<T>>,
  now: () => number = Date.now
): (() => Promise<ReadonlyArray<T>>) => {
  let value: ReadonlyArray<T> | undefined
  let loadedAt = 0
  let inFlight: Promise<ReadonlyArray<T>> | undefined
  const refresh = () => {
    inFlight ??= load()
      .then((loaded) => {
        value = loaded
        loadedAt = now()
        return loaded
      })
      .finally(() => {
        inFlight = undefined
      })
    return inFlight
  }
  return () => {
    const isStale = now() - loadedAt > freshForMs
    // An empty answer (often from before harness detection settled) is
    // cheap to recompute and useless to serve, so it is never served stale.
    if (value === undefined || (isStale && value.length === 0)) return refresh()
    if (isStale) {
      // A failed background refresh leaves the last good answer in place.
      refresh().catch(() => undefined)
    }
    return Promise.resolve(value)
  }
}

export const projectRecommendationsForRequest = async (
  services: CodevisorServerServices,
  url: URL
) => {
  const requestedLimit = Number.parseInt(url.searchParams.get("limit") ?? "12", 10)
  const limit = Math.max(
    0,
    Math.min(Number.isFinite(requestedLimit) ? requestedLimit : 12, maxLimit)
  )
  let recommendations = caches.get(services)
  if (recommendations === undefined) {
    recommendations = makeStaleWhileRevalidate(() => scan(services))
    caches.set(services, recommendations)
  }
  return (await recommendations()).slice(0, limit)
}
