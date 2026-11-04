import { randomUUID } from "node:crypto"

import type { ClaudeContentBlock } from "./attachments.js"
import type { ClaudeSession, PendingSteer, SteerMessage } from "./session.js"

type SteerContent = ReadonlyArray<ClaudeContentBlock>

export const INTERRUPTED_STEP_PREFIX =
  "[Your previous step was interrupted because this message arrived mid-step. Any message " +
  "above about rejecting a tool call and waiting came from the interruption, not from the " +
  "user. Follow this message: it may ask you to stop, change course or carry on.]"

export const steerMessage = (session: ClaudeSession, content: SteerContent): SteerMessage => ({
  message: { content: [...content], role: "user" },
  parent_tool_use_id: null,
  priority: "next",
  session_id: session.sdkSessionId,
  type: "user",
  uuid: randomUUID()
})

export const interruptStepForSteer = (session: ClaudeSession): Promise<boolean> => {
  session.stepInterrupt ??= interruptStep(session).finally(() => {
    session.stepInterrupt = undefined
  })
  return session.stepInterrupt
}

const interruptStep = async (session: ClaudeSession): Promise<boolean> => {
  if (!waitsOnSteer(session)) return false
  if (session.stepInterrupted) return true

  const withdrawn = await withdrawQueuedSteers(session)
  if (withdrawn.length === 0) return true

  session.stepInterrupted = true
  requeueWithPrefix(session, withdrawn)
  await session.q.interrupt()
  return true
}

const waitsOnSteer = (session: ClaudeSession): boolean =>
  session.turnActive &&
  session.pendingSteers.length > 0 &&
  !session.retired &&
  !session.streamEnded &&
  !session.interruptRequested &&
  session.cancelInFlight === undefined

const withdrawQueuedSteers = async (
  session: ClaudeSession
): Promise<ReadonlyArray<PendingSteer>> => {
  const steers = [...session.pendingSteers]
  const cancelled = await Promise.all(steers.map((steer) => cancelQueued(session, steer)))
  return steers.filter((_, index) => cancelled[index])
}

const cancelQueued = (session: ClaudeSession, steer: PendingSteer): Promise<boolean> =>
  session.q.cancelAsyncMessage(steer.message.uuid).catch(() => false)

const requeueWithPrefix = (
  session: ClaudeSession,
  [first, ...rest]: ReadonlyArray<PendingSteer>
): void => {
  if (first === undefined) return

  requeue(session, first, prefixed(first.message.message.content))
  for (const steer of rest) requeue(session, steer, steer.message.message.content)
}

const requeue = (session: ClaudeSession, steer: PendingSteer, content: SteerContent): void => {
  steer.message = steerMessage(session, content)
  session.input.push(steer.message)
}

const prefixed = (content: SteerContent): SteerContent => [
  { text: INTERRUPTED_STEP_PREFIX, type: "text" },
  ...content
]
