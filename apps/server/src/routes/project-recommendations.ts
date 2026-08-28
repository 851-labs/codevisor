import { recommendProjectsFromSessions } from "../project-recommendations.js"
import { run, type CodevisorServerServices } from "../server-context.js"
import { discoverHarnesses } from "./harnesses.js"

export const projectRecommendationsForRequest = async (
  services: CodevisorServerServices,
  url: URL
) => {
  const requestedLimit = Number.parseInt(url.searchParams.get("limit") ?? "12", 10)
  const limit = Number.isFinite(requestedLimit) ? requestedLimit : 12
  const harnesses = await discoverHarnesses(services)
  const sessionGroups = await Promise.all(
    harnesses
      .filter((harness) => harness.enabled && harness.readiness.state === "ready")
      .map(async (harness) => {
        try {
          const account = await services.auth?.activeAccountContext(harness.id)
          return await run(services.agents.listAgentSessions(harness.id, account))
        } catch {
          // One unavailable/corrupt harness store must not hide useful
          // recommendations from every other installed harness.
          return []
        }
      })
  )
  return recommendProjectsFromSessions(sessionGroups.flat(), { limit })
}
