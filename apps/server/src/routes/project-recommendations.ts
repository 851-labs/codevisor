import { homedir } from "node:os"

import type { AgentSessionSummary, Harness, ProjectRecommendation } from "@codevisor/api"

import { recommendProjectsFromSessions } from "../project-recommendations.js"
import { folderAccess, readFolderDecisions, type FolderMachine } from "../protected-folders.js"
import { run, type CodevisorServerServices } from "../server-context.js"
import { discoverHarnesses } from "./harnesses.js"

export const sessionScanLimit = 50

const freshForMs = 15_000

const caches = new WeakMap<
  CodevisorServerServices,
  () => Promise<ReadonlyArray<ProjectRecommendation>>
>()

export const scanProjectRecommendations = async (
  services: CodevisorServerServices,
  includesHarness: (harness: Harness) => boolean
): Promise<ReadonlyArray<ProjectRecommendation>> =>
  recommendFromHarnesses(services, (await discoverHarnesses(services)).filter(includesHarness))

export const recommendFromHarnesses = async (
  services: CodevisorServerServices,
  harnesses: ReadonlyArray<Harness>
): Promise<ReadonlyArray<ProjectRecommendation>> => {
  const sessions = await listHarnessSessions(services, harnesses)
  const access = folderAccess(await readFolderDecisions(services), systemFolderMachine())
  return recommendProjectsFromSessions(sessions, { limit: sessionScanLimit, access })
}

export const listHarnessSessions = async (
  services: CodevisorServerServices,
  harnesses: ReadonlyArray<Harness>
): Promise<ReadonlyArray<AgentSessionSummary>> => {
  const sessionGroups = await Promise.all(
    harnesses.map(async (harness) => {
      try {
        const account = await services.auth?.activeAccountContext(harness.id)
        return await run(services.agents.listAgentSessions(harness.id, account, { titles: false }))
      } catch {
        return []
      }
    })
  )
  return sessionGroups.flat()
}

const systemFolderMachine = (): FolderMachine => ({
  platform: process.platform,
  homeDirectory: homedir()
})

const isUsableHarness = (harness: Harness): boolean =>
  harness.enabled && harness.readiness.state === "ready"

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
    Math.min(Number.isFinite(requestedLimit) ? requestedLimit : 12, sessionScanLimit)
  )
  let recommendations = caches.get(services)
  if (recommendations === undefined) {
    recommendations = makeStaleWhileRevalidate(() =>
      scanProjectRecommendations(services, isUsableHarness)
    )
    caches.set(services, recommendations)
  }
  return (await recommendations()).slice(0, limit)
}
