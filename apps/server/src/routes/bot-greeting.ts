import type { Bot } from "@codevisor/api"

import {
  run,
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { greetingText } from "./bot-greeting-text.js"
import { syncBotInstructions } from "./bot-instructions.js"
import { drainPromptQueue } from "./prompt-queue.js"

export const greetNewBot = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  bot: Bot
): Promise<void> => {
  await syncBotInstructions(services, bot)
  await run(
    services.db.createPromptQueueItem(
      bot.sessionId,
      greetingText,
      [],
      undefined,
      undefined,
      "system"
    )
  )
  void drainPromptQueue(services, fanout, routeState, serverId, bot.sessionId).catch(swallowError)
}
