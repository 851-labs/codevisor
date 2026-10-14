import type { ProjectRecommendation } from "@codevisor/api"

import { recommendProjectsFromSessions } from "../project-recommendations.js"
import { run, type CodevisorServerServices } from "../server-context.js"
import { discoverHarnesses } from "./harnesses.js"

const maxLimit = 50

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
          return await run(
            services.agents.listAgentSessions(harness.id, account, { titles: false })
          )
        } catch {
          return []
        }
      })
  )
  return recommendProjectsFromSessions(sessionGroups.flat(), { limit: maxLimit })
}

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
    if (value === undefined || (isStale && value.length === 0)) return refresh()
    if (isStale) {
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
