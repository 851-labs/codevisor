import {
  isCompactPrompt,
  type AgentSessionMetadata,
  type SteerSettlement
} from "@codevisor/agent-runtime"
import type { PromptQueueItem } from "@codevisor/api"

import { run, type CodevisorServerServices, type EventFanout } from "../server-context.js"
import { botForChat } from "./bot-turns.js"
import { markAppContextsDelivered } from "./prompt-app-context.js"
import { promptInput } from "./prompt-input.js"
import { publishPromptQueue } from "./prompt-queue-publish.js"
import { answeredPendingQuestion } from "./question-replies.js"
import { ensureAgentSessionFor } from "./session-workspace.js"
import { recordUserPrompt, steeredPrompt } from "./user-prompts.js"

export const steerClaimedPrompt = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  item: PromptQueueItem
): Promise<boolean> => {
  if (await answeredPendingQuestion(services, fanout, serverId, sessionId, item)) {
    await run(services.db.completePromptQueueItem(sessionId, item.id))
    return true
  }

  const steer = await steerIntoRunningTurn(services, fanout, serverId, sessionId, item).catch(
    () => declinedSteer
  )
  if (!steer.steered) {
    await run(services.db.releasePromptQueueItem(sessionId, item.id))
    return false
  }

  if (steer.timing === "nextStep") return holdUntilAbsorbed(services, fanout, sessionId, item)
  await recordUserPrompt(services, fanout, serverId, sessionId, steeredPrompt(item))
  await run(services.db.completePromptQueueItem(sessionId, item.id))
  if (steer.timing === "interruptsStep") await interruptRunningStep(services, steer.agentSessionId)
  return true
}

export const interruptRunningStep = (
  services: CodevisorServerServices,
  agentSessionId: string
): Promise<boolean> => {
  const interrupt = services.agents.interruptStep
  if (interrupt === undefined) return Promise.resolve(false)
  return run(interrupt(agentSessionId))
}

export const settleSteeredPrompt = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  settlement: SteerSettlement
): Promise<void> => {
  if (settlement.outcome === "dropped")
    return releaseDroppedSteer(services, fanout, sessionId, settlement)
  return recordAbsorbedSteer(services, fanout, serverId, sessionId, settlement)
}

type SteerTiming = "immediate" | "nextStep" | "interruptsStep"

interface SteerResult {
  readonly steered: boolean
  readonly timing: SteerTiming
  readonly agentSessionId: string
}

const declinedSteer: SteerResult = { steered: false, timing: "immediate", agentSessionId: "" }

const steerIntoRunningTurn = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  item: PromptQueueItem
): Promise<SteerResult> => {
  const steer = services.agents.steer
  /* v8 ignore next */
  if (steer === undefined) return declinedSteer
  if (isCompactPrompt(item.text)) return declinedSteer

  const agentSession = await ensureAgentSessionFor(services, fanout, serverId, sessionId)
  const timing = await steerTiming(services, sessionId, agentSession)
  const prompt = await promptInput(services, sessionId, item, agentSession.skills)
  const steerId = timing === "immediate" ? undefined : item.id
  const steered = await run(steer(agentSession.sessionId, prompt.input, steerId))
  if (steered) await markAppContextsDelivered(services, sessionId, prompt.delivered)
  return { steered, timing, agentSessionId: agentSession.sessionId }
}

const steerTiming = async (
  services: CodevisorServerServices,
  sessionId: string,
  agentSession: AgentSessionMetadata
): Promise<SteerTiming> => {
  if (agentSession.steersAtNextStep !== true) return "immediate"
  if ((await botForChat(services, sessionId)) === undefined) return "nextStep"
  return "interruptsStep"
}

const holdUntilAbsorbed = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  sessionId: string,
  item: PromptQueueItem
): Promise<boolean> => {
  await run(services.db.markPromptQueueItemSteered(sessionId, item.id))
  await publishPromptQueue(services.db, fanout, sessionId)
  return true
}

const recordAbsorbedSteer = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  settlement: SteerSettlement
): Promise<void> => {
  const item = await run(services.db.takeSteeredPromptQueueItem(sessionId, settlement.id))
  if (item === undefined) return

  const prompt = { ...steeredPrompt(item), startsTurn: settlement.startsTurn }
  await publishPromptQueue(services.db, fanout, sessionId)
  await recordUserPrompt(services, fanout, serverId, sessionId, prompt)
  await run(services.db.completePromptQueueItem(sessionId, item.id))
}

const releaseDroppedSteer = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  sessionId: string,
  settlement: SteerSettlement
): Promise<void> => {
  await run(services.db.releaseSteeredPromptQueueItems(sessionId, settlement.id))
  await publishPromptQueue(services.db, fanout, sessionId)
}
