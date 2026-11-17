import type { SessionSummary } from "@codevisor/api"

import {
  run,
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { makeRuntimeAccountFollower } from "./runtime-account-follower.js"
import { ensureAgentSessionFor } from "./session-workspace.js"

export const followRuntimeAccounts = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string
): (() => void) => {
  const follower = makeRuntimeAccountFollower({
    staleChats: (harnessId) => staleChats(services, harnessId),
    isBusy: (chatId) => isBusy(services, routeState, chatId),
    restart: (chatId) => restartOnAssignedAccount(services, fanout, serverId, chatId)
  })
  return fanout.subscribe((event) => void follower.handle(event).catch(swallowError))
}

const staleChats = async (
  services: CodevisorServerServices,
  harnessId: string
): Promise<ReadonlyArray<string>> => {
  const running = runningAccounts(services, harnessId)
  if (running.size === 0) return []

  const chats = await run(services.db.listSessions)
  return chats.filter((chat) => runsOnOtherAccount(chat, running)).map((chat) => chat.id)
}

const isBusy = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  chatId: string
): Promise<boolean> => {
  if (routeState.activeTurnSessions.has(chatId)) return true
  if (routeState.activePromptSessions.has(chatId)) return true

  const page = await run(services.db.getTranscriptPage(chatId, undefined, 1))
  return (page.backgroundTasks ?? []).length > 0
}

const restartOnAssignedAccount = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  chatId: string
): Promise<void> => {
  const chat = await run(services.db.getSessionSummary(chatId))
  const agentSessionId = chat.agentSessionId
  if (agentSessionId === undefined) return
  if (!runsOnOtherAccount(chat, runningAccounts(services, chat.harnessId))) return

  await ensureAgentSessionFor(services, fanout, serverId, chatId).catch(() =>
    run(services.agents.closeAgentSession(agentSessionId))
  )
}

const runningAccounts = (
  services: CodevisorServerServices,
  harnessId: string
): ReadonlyMap<string, string> =>
  new Map(
    services.agents
      .loadedAgentSessions()
      .flatMap((loaded) =>
        loaded.harnessId === harnessId && loaded.harnessAccountId !== undefined
          ? [[loaded.sessionId, loaded.harnessAccountId] as const]
          : []
      )
  )

const runsOnOtherAccount = (
  chat: SessionSummary,
  running: ReadonlyMap<string, string>
): boolean => {
  if (chat.agentSessionId === undefined || chat.harnessAccountId === undefined) return false

  const runningAccount = running.get(chat.agentSessionId)
  return runningAccount !== undefined && runningAccount !== chat.harnessAccountId
}
