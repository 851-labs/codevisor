import type { EventEnvelope, PromptQueueItem, SessionSummary, TranscriptPage } from "@codevisor/api"

import {
  appendAndPublish,
  run,
  sessionIsArchived,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"

type RecoveryContext = {
  readonly services: CodevisorServerServices
  readonly fanout: EventFanout
  readonly serverId: string
}

type RecoverySnapshot = {
  readonly page: TranscriptPage
  readonly active: TranscriptPage["items"][number] | undefined
  readonly hasOrphanedTurn: boolean
  readonly hasOrphanedTasks: boolean
}

export const reconcileOrphanedSessionTurns = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string
): Promise<void> => {
  const sessions = await run(services.db.listSessions)
  const context = { services, fanout, serverId }
  for (const session of sessions) await reconcileSession(context, session)
}

const reconcileSession = async (
  context: RecoveryContext,
  session: SessionSummary
): Promise<void> => {
  const { services, fanout, serverId } = context
  if (await sessionIsArchived(services, session)) {
    // Archived chats get no turn restoration, but unarchiving must not
    // resurface a stale streaming row as an endless in-progress turn.
    await run(services.db.closeStaleAssistantChatItems(session.id))
    return
  }
  const snapshot = await inspectSession(services, session.id)
  const processingPrompts = await reconcilePromptClaims(services, session.id)
  const { page, hasOrphanedTurn, hasOrphanedTasks } = snapshot
  if (!hasOrphanedTurn && !hasOrphanedTasks && processingPrompts.length === 0) return

  // The old provider's resolver vanished. Cancel its persisted question
  // before ending the turn so replay cannot leave an answerable request.
  if (hasOrphanedTurn && page.pendingQuestion !== undefined) {
    await cancelPersistedQuestion(services, fanout, serverId, session.id, page.pendingQuestion)
  }
  // Clear process-owned tasks before the terminal event. A crash between
  // appends leaves the generating turn available for the next recovery pass.
  if (hasOrphanedTasks) await clearBackgroundTasks(services, fanout, serverId, session.id)
  if (processingPrompts.length > 0) {
    await restorePromptMessages(context, session.id, processingPrompts)
  }
  if (hasOrphanedTurn || processingPrompts.length > 0) {
    await recoverTerminalTurn(context, session.id, snapshot, processingPrompts)
  }
}

const inspectSession = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<RecoverySnapshot> => {
  const page = await run(services.db.getTranscriptPage(sessionId, undefined, 1))
  const active = page.items.at(-1)
  const hasOrphanedTurn = active?.role === "assistant" && active.isGenerating
  // Startup precedes client admission: every streaming row is dead. Older
  // rows settle silently; the newest orphan keeps its full terminal context.
  await run(
    services.db.closeStaleAssistantChatItems(sessionId, hasOrphanedTurn ? active.id : undefined)
  )
  // Current database projections always supply this optional API field.
  const hasOrphanedTasks = page.backgroundTasks!.length > 0
  return { page, active, hasOrphanedTurn, hasOrphanedTasks }
}

const reconcilePromptClaims = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<Array<PromptQueueItem>> => {
  const claimedPrompts = await run(services.db.listProcessingPromptQueue(sessionId))
  const processingPrompts: Array<PromptQueueItem> = []
  for (const item of claimedPrompts) {
    if (await run(services.db.hasTerminalAssistantAfterMessage(sessionId, item.id))) {
      // A terminal chat row proves that only acknowledgement was lost.
      await run(services.db.completePromptQueueItem(sessionId, item.id))
    } else {
      processingPrompts.push(item)
    }
  }
  return processingPrompts
}

const restorePromptMessages = async (
  { services, fanout, serverId }: RecoveryContext,
  sessionId: string,
  processingPrompts: ReadonlyArray<PromptQueueItem>
): Promise<void> => {
  for (const item of processingPrompts) {
    if (!(await run(services.db.hasConversationMessage(sessionId, item.id)))) {
      await restorePromptMessage(services, fanout, serverId, sessionId, item)
    }
  }
}

const recoverTerminalTurn = async (
  context: RecoveryContext,
  sessionId: string,
  { active, hasOrphanedTurn }: RecoverySnapshot,
  processingPrompts: ReadonlyArray<PromptQueueItem>
): Promise<void> => {
  const { services, fanout, serverId } = context
  let terminalTurnId = hasOrphanedTurn ? active!.turnId : undefined
  if (!hasOrphanedTurn && processingPrompts.length > 0) {
    terminalTurnId = `recovered-prompt:${processingPrompts[0]!.id}`
    await startRecoveredTurn(services, fanout, serverId, sessionId, terminalTurnId)
  }
  // Keep each claim durable until a generating row exists: every crash point
  // must leave a marker for the next startup pass before acknowledging input.
  for (const item of processingPrompts) {
    await run(services.db.completePromptQueueItem(sessionId, item.id))
  }
  await settleRecoveredTurn(services, fanout, serverId, sessionId, terminalTurnId)
}

const cancelPersistedQuestion = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  question: NonNullable<TranscriptPage["pendingQuestion"]>
): Promise<EventEnvelope> =>
  appendAndPublish(services.db, fanout, "session.output", sessionId, {
    outcome: "cancelled",
    questionId: question.questionId,
    questions: question.questions,
    sessionUpdate: "question_resolved",
    serverId
  })

const clearBackgroundTasks = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string
): Promise<EventEnvelope> =>
  appendAndPublish(services.db, fanout, "session.updated", sessionId, {
    backgroundTasks: [],
    serverId
  })

const restorePromptMessage = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  item: PromptQueueItem
): Promise<EventEnvelope> =>
  appendAndPublish(services.db, fanout, "session.output", sessionId, {
    role: "user",
    messageId: item.id,
    text: item.text,
    ...(item.attachments === undefined ? {} : { attachments: item.attachments }),
    serverId
  })

const startRecoveredTurn = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  turnId: string
): Promise<EventEnvelope> =>
  appendAndPublish(services.db, fanout, "session.updated", sessionId, {
    initiatedBy: "user",
    turnId,
    turnState: "started",
    serverId
  })

const settleRecoveredTurn = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  turnId: string | undefined
): Promise<EventEnvelope> =>
  appendAndPublish(services.db, fanout, "session.updated", sessionId, {
    ...(turnId === undefined ? {} : { initiatedBy: "user", turnId, turnState: "ended" }),
    serverId,
    stopReason: "end_turn"
  })
