import {
  run,
  sessionIsArchived,
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { autoResumePrompt } from "./auto-resume-prompt.js"
import { makeAutoResumeScheduler, type AutoResumeScheduler } from "./auto-resume-scheduler.js"
import { drainPromptQueue } from "./prompt-queue.js"
import { readSessionUsageLimits } from "./session-usage-limits.js"

export const makeServerAutoResume = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string
): AutoResumeScheduler =>
  makeAutoResumeScheduler({
    db: services.db,
    fanout,
    readLimits: async (sessionId) => {
      const session = await run(services.db.getSessionSummary(sessionId))
      return (await readSessionUsageLimits(services, session)).limits
    },
    activeAccountId: async (harnessId) =>
      (await run(services.db.listHarnessAccounts(harnessId))).find((account) => account.isActive)
        ?.id,
    resume: (sessionId) => resumeInterruptedTurn(services, fanout, routeState, serverId, sessionId)
  })

const resumeInterruptedTurn = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  sessionId: string
): Promise<void> => {
  const session = await run(services.db.getSessionSummary(sessionId))
  if (await sessionIsArchived(services, session)) throw new Error("The chat was archived")

  const text = autoResumePrompt(session, await interruptedRequest(services, sessionId))
  await run(services.db.createPromptQueueItem(sessionId, text, [], undefined, undefined, "system"))
  void drainPromptQueue(services, fanout, routeState, serverId, sessionId).catch(swallowError)
}

const recentItemsLimit = 20

const interruptedRequest = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<string | undefined> => {
  const page = await run(services.db.getTranscriptPage(sessionId, undefined, recentItemsLimit))
  return page.items.findLast((item) => item.role === "user" && item.origin === undefined)?.text
}
