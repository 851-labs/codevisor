import type { SessionSummary, Workspace } from "@codevisor/api"
import type { DeferredArchiveTarget } from "@codevisor/db"

import type { ArchiveContext } from "../archive-jobs.js"
import { scheduleDeferredArchive } from "../deferred-archives.js"
import { HttpFailure } from "../server-context.js"
import type { RouteContext } from "./route-context.js"
import { findSession } from "./session-workspace.js"
import { sameId } from "./workspace-lookups.js"

export interface ScheduledArchive {
  readonly archived: false
  readonly scheduled: true
  readonly message: string
}

export const archiveContextOf = ({
  services,
  fanout,
  config,
  routeState
}: RouteContext): ArchiveContext => ({ services, fanout, config, turns: routeState })

export const callerOf = async (
  { services }: RouteContext,
  callerAgentId: string | undefined
): Promise<SessionSummary | undefined> => {
  if (callerAgentId === undefined) return undefined
  const caller = await findSession(services.db, callerAgentId)
  if (caller === undefined) throw new HttpFailure(422, `Unknown caller: ${callerAgentId}`)
  return caller
}

export const isInside = (
  caller: SessionSummary | undefined,
  workspace: Workspace
): caller is SessionSummary =>
  caller?.workspaceId !== undefined && sameId(caller.workspaceId, workspace.id)

export const deferWorkspaceArchive = async (
  route: RouteContext,
  caller: SessionSummary,
  workspace: Workspace
): Promise<ScheduledArchive> => {
  await scheduleDeferredArchive(archiveContextOf(route), {
    sessionId: caller.id,
    target: "workspace",
    workspaceId: workspace.id
  })
  return scheduled("workspace")
}

export const deferChatArchive = async (
  route: RouteContext,
  caller: SessionSummary
): Promise<ScheduledArchive> => {
  await scheduleDeferredArchive(archiveContextOf(route), { sessionId: caller.id, target: "chat" })
  return scheduled("chat")
}

const scheduled = (target: DeferredArchiveTarget): ScheduledArchive => ({
  archived: false,
  scheduled: true,
  message: `Archives when your turn ends: ${whatArchives[target]} End your turn now. If the user sends a message first, the archive is cancelled.`
})

const whatArchives: Readonly<Record<DeferredArchiveTarget, string>> = {
  workspace:
    "this workspace and every agent in it are archived, the same as when the user archives it from the sidebar.",
  chat: "your chat is archived and its tab closes, the same as when the user archives it."
}
