import type { Bot, SessionSummary } from "@codevisor/api"

import { run, type CodevisorServerServices, type RouteState } from "../server-context.js"
import { sessionIsArchived } from "../server-workspace-effects.js"
import { HANDOFF_MESSAGE_LIMIT, handoffText, type HandoffAgent } from "./bot-handoff-text.js"
import { hasLiveTurn } from "./prompt-queue.js"

export interface ForkHandoff {
  readonly source: Bot
  readonly targetHarnessId: string
  readonly agents: ReadonlyArray<SessionSummary>
  readonly agentsMachineName?: string | undefined
}

export const forkHandoffText = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  handoff: ForkHandoff
): Promise<string> =>
  handoffText({
    sourceName: handoff.source.name,
    sourceHarness: harnessName(services, handoff.source.harnessId),
    targetHarness: harnessName(services, handoff.targetHarnessId),
    messages: await recentMessages(services, handoff.source),
    agents: await handoffAgents(services, routeState, handoff)
  })

const harnessName = (services: CodevisorServerServices, harnessId: string): string =>
  services.agents.catalog.find((definition) => definition.id === harnessId)?.name ?? harnessId

const recentMessages = async (services: CodevisorServerServices, bot: Bot) => {
  const page = await run(
    services.db.listBotMessages(bot.sessionId, undefined, HANDOFF_MESSAGE_LIMIT)
  )
  return page.messages
}

const handoffAgents = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  handoff: ForkHandoff
): Promise<ReadonlyArray<HandoffAgent>> => {
  const active: Array<HandoffAgent> = []
  for (const agent of handoff.agents) {
    if (await sessionIsArchived(services, agent)) continue
    active.push({
      id: agent.id,
      title: agent.title,
      isWorking: hasLiveTurn(routeState, agent.id),
      machineName: handoff.agentsMachineName
    })
  }
  return active
}
