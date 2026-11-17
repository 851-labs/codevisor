import {
  decode,
  isoTimestamp,
  RESTORED_AGENT_SESSION_LABEL,
  SandboxChatsAction,
  type FileMetadata,
  type SavedChat,
  type SavedChatList,
  type SavedChatPane,
  type SavedChatSession,
  type SessionSummary
} from "@codevisor/api"
import { SAVED_CHAT_FORMAT } from "@codevisor/db"

import { appendAndPublish, HttpFailure, run } from "../server-context.js"
import { receiveImportFile } from "./bot-import-files.js"
import type { FleetCall } from "./fleet-calls.js"
import type { RouteContext } from "./route-context.js"
import { createSessionIfMissing } from "./session-workspace.js"
import { publishPaneUpdated } from "./workspace-panes.js"

type Action<Name extends SandboxChatsAction["action"]> = Extract<
  SandboxChatsAction,
  { readonly action: Name }
>

export const receiveSandboxChats = async (
  route: RouteContext,
  call: FleetCall,
  args: unknown
): Promise<unknown> => {
  if (!call.verified) throw new HttpFailure(403, "Only machines on this account can move chats")
  const action = actionOf(args)
  const { db } = route.services
  if (action.action === "list") return savedChats(route, action.workspaceId)
  if (action.action === "item") return run(db.exportChatItem(action.itemId))
  if (action.action === "file") return fileChunk(route, action)
  if (action.action === "restore_file") {
    return receiveImportFile(route.services, action, "restore the sandbox again to resend it")
  }

  requireFormat(action.format)
  if (action.action === "restore_chat") return restoreChat(route, action)
  if (action.action === "restore_item") {
    await run(db.importChatItem(action.sessionId, action.item))
    return { restored: true }
  }
  if (action.action === "restore_pane") return restorePane(route, action)
  return finishChat(route, action)
}

const requireFormat = (format: number): void => {
  if (format === SAVED_CHAT_FORMAT) return
  throw new HttpFailure(
    422,
    `These chats were saved in format ${String(format)}, and this sandbox's Codevisor reads format ${String(SAVED_CHAT_FORMAT)}`
  )
}

const savedChats = async (route: RouteContext, workspaceId: string): Promise<SavedChatList> => {
  const sessions = await run(route.services.db.listSessions)
  const inWorkspace = sessions.filter((session) => sameId(session.workspaceId, workspaceId))
  const chats: Array<SavedChat> = []
  for (const session of inWorkspace) chats.push(await savedChat(route, session))
  return { format: SAVED_CHAT_FORMAT, chats, panes: await chatPanes(route, workspaceId, chats) }
}

const chatPanes = async (
  { services }: RouteContext,
  workspaceId: string,
  chats: ReadonlyArray<SavedChat>
): Promise<ReadonlyArray<SavedChatPane>> => {
  const chatIds = new Set(chats.map((chat) => chat.session.id.toLowerCase()))
  const panes = await run(services.db.listWorkspacePanes)
  return panes.flatMap((pane) => {
    const { resourceId } = pane
    if (!sameId(pane.workspaceId, workspaceId) || pane.resourceKind !== "session") return []
    if (resourceId === undefined || !chatIds.has(resourceId.toLowerCase())) return []
    return [
      {
        id: pane.id,
        providerId: pane.providerId,
        paneType: pane.paneType,
        title: pane.title,
        resourceKind: pane.resourceKind,
        resourceId,
        createdAt: pane.createdAt,
        ...(pane.metadata === undefined ? {} : { metadata: pane.metadata })
      }
    ]
  })
}

const restorePane = async (
  route: RouteContext,
  { workspaceId, pane }: Action<"restore_pane">
): Promise<{ readonly restored: true }> => {
  const restored = await run(route.services.db.upsertWorkspacePane(workspaceId, pane))
  await publishPaneUpdated(route, restored)
  return { restored: true }
}

const savedChat = async (
  { services }: RouteContext,
  session: SessionSummary
): Promise<SavedChat> => {
  const itemIds = await run(services.db.listChatItemIds(session.id))
  const files: Array<FileMetadata> = []
  for (const fileId of await run(services.db.listChatFileIds(session.id))) {
    const file = await run(services.db.getFileMetadata(fileId))
    if (file !== undefined) files.push(file)
  }
  return { session: savedSession(session), itemIds, files }
}

const savedSession = (session: SessionSummary): SavedChatSession => ({
  id: session.id,
  title: session.title,
  harnessId: session.harnessId,
  createdAt: session.createdAt,
  ...(hasAgentSession(session) ? { agentSessionId: session.agentSessionId } : {}),
  ...(session.updatedAt === undefined ? {} : { updatedAt: session.updatedAt }),
  ...(session.createdBy === undefined ? {} : { createdBy: session.createdBy }),
  ...(session.labels === undefined ? {} : { labels: session.labels }),
  ...(session.configSelections === undefined ? {} : { configSelections: session.configSelections })
})

const fileChunk = async (
  { services }: RouteContext,
  action: Action<"file">
): Promise<{ readonly data: string }> => {
  const file = await run(services.db.getFileMetadata(action.fileId))
  if (file === undefined) throw new HttpFailure(404, `File not found: ${action.fileId}`)

  const bytes = await services.attachments.read(file)
  return { data: bytes.subarray(action.offset, action.offset + action.length).toString("base64") }
}

const restoreChat = async (
  route: RouteContext,
  { workspaceId, session }: Action<"restore_chat">
): Promise<{ readonly sessionId: string }> => {
  const { services, fanout, routeState, config } = route
  const workspace = (await run(services.db.listWorkspaces)).find((candidate) =>
    sameId(candidate.id, workspaceId)
  )
  if (workspace === undefined) throw new HttpFailure(404, `Workspace not found: ${workspaceId}`)

  const { agentSessionId: _resumedLater, ...fields } = session
  const created = await createSessionIfMissing(
    services,
    fanout,
    routeState,
    config,
    {
      ...fields,
      projectId: workspace.projectId,
      workspaceId: workspace.id,
      deferAgentSession: true
    },
    false
  )
  if (!created.created) throw new HttpFailure(409, `${session.title} is already on this sandbox`)
  return { sessionId: created.session.id }
}

const finishChat = async (
  { services, fanout }: RouteContext,
  action: Action<"finish_chat">
): Promise<{ readonly restored: true }> => {
  const note = { text: action.note, createdAt: isoTimestamp() }
  await run(services.db.finishChatImport(action.sessionId, action.fileIds, note))
  if (action.agentSessionId !== undefined) await resumeFrom(services, action, action.agentSessionId)
  const session = await run(services.db.getSessionSummary(action.sessionId))
  await appendAndPublish(services.db, fanout, "session.created", session.id, session)
  return { restored: true }
}

const resumeFrom = async (
  services: RouteContext["services"],
  { sessionId }: Action<"finish_chat">,
  agentSessionId: string
): Promise<void> => {
  const { labels, harnessId } = await run(services.db.getSessionSummary(sessionId))
  const account = await services.auth?.activeAccountContext(harnessId)
  await run(
    services.db.updateSession(sessionId, {
      agentSessionId,
      labels: { ...labels, [RESTORED_AGENT_SESSION_LABEL]: agentSessionId },
      ...(account === undefined ? {} : { harnessAccountId: account.id })
    })
  )
}

const hasAgentSession = (session: SessionSummary): boolean =>
  session.agentSessionId !== undefined && session.agentSessionId !== ""

const sameId = (left: string | undefined, right: string): boolean =>
  left?.toLowerCase() === right.toLowerCase()

const actionOf = (args: unknown): SandboxChatsAction => {
  try {
    return decode(SandboxChatsAction)(args)
  } catch {
    throw new HttpFailure(400, "Expected a sandbox chats action")
  }
}
