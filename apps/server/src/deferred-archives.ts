import type { DeferredArchive, DeferredArchiveRequest } from "@codevisor/db"

import { archiveChatAndOwned, archiveWorkspaceNow, type ArchiveContext } from "./archive-jobs.js"
import type { CodevisorServerServices } from "./server-context-types.js"
import { run, swallowError } from "./server-http.js"

export interface DeferredArchives {
  readonly turnFinished: (sessionId: string) => void
}

export const startDeferredArchives = (context: ArchiveContext): DeferredArchives => {
  void runDueArchives(context).catch(swallowError)
  return {
    turnFinished: (sessionId) => void runArchiveIfDue(context, sessionId).catch(swallowError)
  }
}

export const scheduleDeferredArchive = async (
  context: ArchiveContext,
  request: DeferredArchiveRequest
): Promise<void> => {
  await run(context.services.db.scheduleDeferredArchive(request))
  void runArchiveIfDue(context, request.sessionId).catch(swallowError)
}

export const cancelDeferredArchivesFor = (
  services: CodevisorServerServices,
  sessionId: string
): Promise<ReadonlyArray<string>> => run(services.db.cancelDeferredArchivesFor(sessionId))

export const runDueArchives = async (context: ArchiveContext): Promise<void> => {
  const due = await run(context.services.db.listDueDeferredArchives)
  for (const archive of due) await runArchiveIfDue(context, archive.sessionId)
}

const running = new WeakMap<CodevisorServerServices, Set<string>>()

const runningFor = (services: CodevisorServerServices): Set<string> => {
  let sessions = running.get(services)
  if (sessions === undefined) {
    sessions = new Set()
    running.set(services, sessions)
  }
  return sessions
}

const runArchiveIfDue = async (context: ArchiveContext, sessionId: string): Promise<void> => {
  const sessions = runningFor(context.services)
  const key = sessionId.toLowerCase()
  if (sessions.has(key)) return

  sessions.add(key)
  try {
    const due = await run(context.services.db.getDueDeferredArchive(sessionId))
    if (due !== undefined) await runArchive(context, due)
  } finally {
    sessions.delete(key)
  }
}

const runArchive = (context: ArchiveContext, archive: DeferredArchive): Promise<void> => {
  if (archive.target === "workspace") return archiveWorkspaceLater(context, archive)
  return archiveChatLater(context, archive)
}

const archiveWorkspaceLater = async (
  context: ArchiveContext,
  archive: DeferredArchive
): Promise<void> => {
  const workspaceId = archive.workspaceId?.toLowerCase()
  const workspace = (await run(context.services.db.listWorkspaces)).find(
    (candidate) => candidate.id.toLowerCase() === workspaceId
  )
  if (workspace === undefined || workspace.isArchived) return forget(context, archive)

  await archiveWorkspaceNow(context, workspace)
}

const archiveChatLater = async (context: ArchiveContext, archive: DeferredArchive) => {
  const chat = await run(context.services.db.getSessionSummary(archive.sessionId))
  if (chat.isArchived === true) return forget(context, archive)

  await archiveChatAndOwned(context, chat)
}

const forget = async (context: ArchiveContext, archive: DeferredArchive): Promise<void> => {
  await run(context.services.db.deleteDeferredArchive(archive.sessionId))
}
