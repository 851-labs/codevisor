import { stat } from "node:fs/promises"

import { unavailableUsageLimits, type HarnessAccountContext } from "@codevisor/agent-runtime"
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
  if (cwd === undefined) return unreadable(session, noWorkspaceDetail, undefined)
  if (!(await isDirectory(cwd))) return unreadable(session, missingWorkspaceDetail, undefined)

  const account = await sessionAccount(services, session)
  if (account.kind === "unusable") return unreadable(session, account.detail, account.id)

  const readLimits = () =>
    run(services.agents.readHarnessUsageLimits(session.harnessId, cwd, account.context))
  const limits = await (services.usageLimits?.read(
    usageLimitsKey(session.harnessId, account.id),
    readLimits
  ) ?? readLimits())
  return { limits, accountId: account.id }
}

type SessionAccount =
  | {
      readonly kind: "usable"
      readonly id: string | undefined
      readonly context: HarnessAccountContext | undefined
    }
  | { readonly kind: "unusable"; readonly id: string | undefined; readonly detail: string }

const noWorkspaceDetail = "This session has no local workspace from which to query its harness."

const missingWorkspaceDetail = "This session's workspace folder no longer exists."

const sessionDirectory = async (
  services: CodevisorServerServices,
  session: SessionSummary
): Promise<string | undefined> => {
  if (session.cwd !== undefined) return session.cwd

  const project = await getProjectOrFail(services.db, session.projectId)
  return project.locations.find((location) => location.serverId === session.serverId)?.folderPath
}

const isDirectory = async (path: string): Promise<boolean> =>
  (await stat(path).catch(() => undefined))?.isDirectory() ?? false

const sessionAccount = async (
  services: CodevisorServerServices,
  session: SessionSummary
): Promise<SessionAccount> => {
  try {
    const context = await sessionAccountContext(services, session)
    return { kind: "usable", id: session.harnessAccountId ?? context?.id, context }
  } catch (cause) {
    return { kind: "unusable", id: session.harnessAccountId, detail: unusableDetail(cause) }
  }
}

const sessionAccountContext = (services: CodevisorServerServices, session: SessionSummary) => {
  if (session.harnessAccountId === undefined) {
    return services.auth?.activeAccountContext(session.harnessId)
  }
  return services.auth?.accountContext(session.harnessAccountId)
}

const unusableDetail = (cause: unknown): string =>
  cause instanceof Error ? cause.message : "This session's harness account can't be used."

const unreadable = (
  session: SessionSummary,
  detail: string,
  accountId: string | undefined
): SessionUsageLimits => ({
  limits: unavailableUsageLimits(session.harnessId, detail),
  accountId
})
