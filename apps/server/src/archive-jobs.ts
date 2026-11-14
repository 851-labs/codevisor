import type { SessionSummary, Workspace, WorkspacePane } from "@codevisor/api"

import {
  archiveAgentsCreatedBy,
  archiveAgentsCreatedIn,
  archiveLocalChildren,
  type ArchiveOwned,
  type Creators
} from "./created-agents-archive.js"
import { publishPromptQueue } from "./routes/prompt-queue-publish.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout
} from "./server-context-types.js"
import { appendAndPublish, run, swallowError } from "./server-http.js"
import {
  archiveUnusedWorktree,
  archiveWorkspaceWorktree,
  captureWorkspaceRuntime,
  chatCheckoutsBeside,
  forgetRetiredSessionTurn,
  restoreWorkspaceWorktree,
  type RestoredWorkspace,
  retireWorkspaceRuntime,
  type RetiredTurnState,
  type WorkspaceRuntime
} from "./server-workspace-effects.js"
import { clearStoppedTasks } from "./stopped-tasks.js"
import { stopWorkspaceExecTasks } from "./workspace-exec-tasks.js"
import { withWorktreeLifecycle } from "./worktree-lifecycle.js"

export interface ArchiveJobs {
  readonly track: (work: Promise<void>) => void
  readonly idle: () => Promise<void>
  readonly jobsFinished: () => Promise<void>
}

interface ArchiveJobQueue extends ArchiveJobs {
  readonly enqueue: <A>(job: () => Promise<A>) => Promise<A>
}

const queues = new WeakMap<CodevisorServerServices, ArchiveJobQueue>()

const makeQueue = (): ArchiveJobQueue => {
  const outstanding = new Set<Promise<void>>()
  let tail: Promise<void> = Promise.resolve()
  const track = (work: Promise<void>): void => {
    const settled = work.then(swallowError, swallowError)
    outstanding.add(settled)
    void settled.then(() => outstanding.delete(settled))
  }
  return {
    enqueue: (job) => {
      const result = tail.then(job)
      tail = result.then(swallowError, swallowError)
      track(tail)
      return result
    },
    track,
    jobsFinished: () => tail,
    idle: async () => {
      while (outstanding.size > 0) await Promise.all(outstanding)
    }
  }
}

const queueFor = (services: CodevisorServerServices): ArchiveJobQueue => {
  let queue = queues.get(services)
  if (queue === undefined) {
    queue = makeQueue()
    queues.set(services, queue)
  }
  return queue
}

export const archiveJobs = (services: CodevisorServerServices): ArchiveJobs => queueFor(services)

const findWorkspace = async (
  services: CodevisorServerServices,
  workspaceId: string
): Promise<Workspace | undefined> =>
  (await run(services.db.listWorkspaces)).find(
    (candidate) => candidate.id.toLowerCase() === workspaceId.toLowerCase()
  )

export const enqueueWorkspaceArchive = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  workspace: Workspace,
  runtime?: WorkspaceRuntime
): Promise<void> =>
  archiveWorkspaceAndWait(services, fanout, config, workspace, runtime).catch(swallowError)

export const archiveWorkspaceAndWait = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  workspace: Workspace,
  runtime?: WorkspaceRuntime
): Promise<void> => {
  const queue = queueFor(services)
  return queue.enqueue(async () => {
    const archived = await withWorktreeLifecycle(
      services,
      workspace.rootDirectory ?? workspace.id,
      async () => {
        if ((await findWorkspace(services, workspace.id))?.isArchived === false) return false
        await services.workspaceMirrors?.stopAll(workspace.id)
        await stopWorkspaceExecTasks(services, workspace.id)
        if (runtime !== undefined) await retireRuntime(services, fanout, config.id, runtime)
        queue.track((await archiveWorkspaceWorktree(services, config.id, workspace)).purged)
        return true
      }
    )
    if (archived) await reclaimChatWorktrees(services, config.id, workspace, runtime, queue)
  })
}

const reclaimChatWorktrees = async (
  services: CodevisorServerServices,
  serverId: string,
  workspace: Workspace,
  runtime: WorkspaceRuntime | undefined,
  queue: ArchiveJobQueue
): Promise<void> => {
  const checkouts = await chatCheckoutsBeside(services, serverId, workspace, runtime?.sessions)
  for (const checkout of checkouts) {
    const archived = await withWorktreeLifecycle(services, checkout.path, () =>
      archiveUnusedWorktree(services, serverId, checkout)
    )
    queue.track(archived.purged)
  }
}

export const reclaimArchivedChat = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  chat: SessionSummary
): Promise<void> => {
  const queue = queueFor(services)
  return queue.enqueue(async () => {
    await retireRuntime(services, fanout, config.id, { sessions: [chat], terminalKeys: [] })
    const checkout = (await run(services.db.listCheckouts)).find(
      (candidate) => candidate.id === chat.checkoutId
    )
    if (checkout === undefined || checkout.worktreeName === undefined) return
    if (checkout.serverId !== config.id) return
    const archived = await withWorktreeLifecycle(services, checkout.path, () =>
      archiveUnusedWorktree(services, config.id, checkout)
    )
    queue.track(archived.purged)
  })
}

const retireRuntime = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  runtime: WorkspaceRuntime
): Promise<void> => {
  await retireWorkspaceRuntime(services, runtime)
  for (const session of runtime.sessions)
    await clearStoppedTasks(services, fanout, serverId, session.id)
}

export interface ArchiveContext {
  readonly services: CodevisorServerServices
  readonly fanout: EventFanout
  readonly config: CodevisorServerConfig
  readonly turns: RetiredTurnState
}

export const archiveAgentsOf = (context: ArchiveContext, agentIds: ReadonlyArray<string>) =>
  archiveAgentsCreatedBy(context.services, context.config.id, agentIds, archiveChild(context))

export const archiveAgentsOfWorkspace = (context: ArchiveContext, workspace: Workspace) =>
  archiveAgentsCreatedIn(context.services, context.config.id, workspace, archiveChild(context))

export const archiveAgentsOfRemote = (context: ArchiveContext, creators: Creators) =>
  archiveLocalChildren(context.services, creators, archiveChild(context))

const archiveChild = (context: ArchiveContext): ArchiveOwned => ({
  workspace: async (child) => {
    const { services, fanout, config, turns } = context
    const archived = await run(services.db.updateWorkspace(child.id, { isArchived: true }))
    await applyWorkspaceArchiveEffects(services, fanout, config, turns, archived, false)
  },
  chat: (chat) => archiveChatAndOwned(context, chat)
})

export const archiveChatAndOwned = async (
  context: ArchiveContext,
  chat: SessionSummary
): Promise<void> => {
  const { services, fanout, config, turns } = context
  await clearPromptQueue(services, fanout, chat.id)
  forgetRetiredSessionTurn(turns, chat.id)
  await run(services.db.archiveSession(chat.id))
  await closeChatTabs(services, fanout, chat.id)
  await reclaimArchivedChat(services, fanout, config, chat)
  await archiveAgentsOf(context, [chat.id])
}

const clearPromptQueue = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  chatId: string
): Promise<void> => {
  const queue = await run(services.db.listPromptQueue(chatId))
  if (queue.length === 0) return
  for (const item of queue) await run(services.db.deletePromptQueueItem(chatId, item.id))
  await publishPromptQueue(services.db, fanout, chatId)
}

export const closeTabsOfRemoteChats = async (
  { services, fanout }: ArchiveContext,
  { creatorIds, creatorMachineId }: Creators
): Promise<void> => {
  const ids = new Set(creatorIds.map((id) => id.toLowerCase()))
  await closeTabs(
    services,
    fanout,
    (pane) =>
      pane.resourceServerId === creatorMachineId && ids.has(pane.resourceId?.toLowerCase() ?? "")
  )
}

const closeChatTabs = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  chatId: string
): Promise<void> => closeTabs(services, fanout, (pane) => pane.resourceId === chatId)

const closeTabs = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  showsChat: (pane: WorkspacePane) => boolean
): Promise<void> => {
  const tabs = (await run(services.db.listWorkspacePanes)).filter(
    (pane) => pane.resourceKind === "session" && showsChat(pane)
  )
  for (const tab of tabs) {
    await run(services.db.deleteWorkspacePane(tab.workspaceId, tab.id))
    await appendAndPublish(services.db, fanout, "workspace.pane.deleted", tab.id, {
      id: tab.id,
      workspaceId: tab.workspaceId
    })
  }
}

export const applyWorkspaceArchiveEffects = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  turns: RetiredTurnState,
  workspace: Workspace,
  wasArchived: boolean
): Promise<Workspace> => {
  const context = { services, fanout, config, turns }
  await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
  if (workspace.isArchived === wasArchived) return workspace

  if (workspace.isArchived) {
    const runtime = await captureWorkspaceRuntime(services, turns, workspace)
    void enqueueWorkspaceArchive(services, fanout, config, workspace, runtime)
    await archiveAgentsCreatedIn(services, config.id, workspace, archiveChild(context))
    return workspace
  }

  const restored = await restoreOrStayArchived(services, fanout, config.id, workspace)
  if (!restored.restoredFiles) {
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, {
      ...restored.workspace,
      archiveRestoreIncomplete: true
    })
    return restored.workspace
  }
  if (restored.workspace !== workspace) {
    await appendAndPublish(
      services.db,
      fanout,
      "workspace.updated",
      workspace.id,
      restored.workspace
    )
  }
  return restored.workspace
}

const restoreOrStayArchived = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  workspace: Workspace
): Promise<RestoredWorkspace> => {
  try {
    return await restoreWorkspaceWorktree(services, serverId, workspace)
  } catch (cause) {
    const archived = await run(services.db.updateWorkspace(workspace.id, { isArchived: true }))
    await appendAndPublish(services.db, fanout, "workspace.updated", archived.id, archived)
    throw cause
  }
}
