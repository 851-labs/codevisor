import {
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { syncAllBotInstructions } from "./bot-instructions.js"
import { tellBot } from "./bot-projects.js"

export const updateAllBotInstructions = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string
): Promise<void> => {
  const changed = await syncAllBotInstructions(services)
  for (const bot of changed.filter((candidate) => !candidate.isArchived)) {
    await tellBot(
      services,
      fanout,
      routeState,
      serverId,
      bot,
      "bot.instructions_updated",
      instructionsUpdatedNotice
    ).catch(swallowError)
  }
}

const instructionsUpdatedNotice =
  "Codevisor updated its instructions in AGENTS.md. Reread the file before your next reply; " +
  "anything you had added yourself is under Notes. This needs no reply."
