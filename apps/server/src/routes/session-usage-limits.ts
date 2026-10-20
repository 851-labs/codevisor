import type { HarnessUsageLimits, SessionSummary } from "@codevisor/api"

import { usageLimitsKey } from "../infra/usage-limits-cache.js"
import { getProjectOrFail, run, type CodevisorServerServices } from "../server-context.js"

export interface SessionUsageLimits {
  readonly limits: HarnessUsageLimits
  readonly accountId: string | undefined
}

export const readSessionUsageLimits = async (
  services: CodevisorServerServices,
  session: SessionSummary
): Promise<SessionUsageLimits> => {
  const cwd = await sessionDirectory(services, session)
  if (cwd === undefined) return { limits: noWorkspaceLimits(session), accountId: undefined }

  const accountContext = await sessionAccountContext(services, session)
  const accountId = session.harnessAccountId ?? accountContext?.id
  const readLimits = () =>
    run(services.agents.readHarnessUsageLimits(session.harnessId, cwd, accountContext))
  const limits = await (services.usageLimits?.read(
    usageLimitsKey(session.harnessId, accountId),
    readLimits
  ) ?? readLimits())
  return { limits, accountId }
}

const sessionDirectory = async (
  services: CodevisorServerServices,
  session: SessionSummary
): Promise<string | undefined> => {
  if (session.cwd !== undefined) return session.cwd

  const project = await getProjectOrFail(services.db, session.projectId)
  return project.locations.find((location) => location.serverId === session.serverId)?.folderPath
}

const sessionAccountContext = (services: CodevisorServerServices, session: SessionSummary) => {
  if (session.harnessAccountId === undefined) {
    return services.auth?.activeAccountContext(session.harnessId)
  }
  return services.auth?.accountContext(session.harnessAccountId)
}

const noWorkspaceLimits = (session: SessionSummary): HarnessUsageLimits => ({
  detail: "This session has no local workspace from which to query its harness.",
  fetchedAt: new Date().toISOString(),
  harnessId: session.harnessId,
  state: "unavailable",
  windows: []
})
