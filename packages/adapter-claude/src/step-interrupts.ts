import type { StepInterruptTiming } from "@codevisor/agent-runtime"

import type { ClaudeSession } from "./session.js"

export const LONG_TOOL_MS = 10_000

export const INTERRUPTED_STEP_NOTE =
  "[Your work was interrupted only so the user's message above could reach you. Nobody " +
  "rejected your tool call and the user isn't waiting for you to stop, so ignore any " +
  "instruction above to stop and wait. Act on the message above, and re-run the interrupted " +
  "call if it's still needed.]"

export const openToolCall = (session: ClaudeSession, toolUseId: string): void => {
  if (session.openToolCalls.size === 0) session.toolsOpenedAt = Date.now()
  session.openToolCalls.add(toolUseId)
}

export const interruptStepForSteer = async (
  session: ClaudeSession,
  timing: StepInterruptTiming
): Promise<boolean> => {
  if (!waitsOnSteer(session)) return false
  if (session.stepInterrupted) return true
  if (timing === "now") return interruptStep(session)
  if (session.openToolCalls.size === 0) return false

  const waitMs = session.toolsOpenedAt + LONG_TOOL_MS - Date.now()
  if (waitMs <= 0) return interruptStep(session)
  setTimeout(() => {
    void interruptStepForSteer(session, timing).catch(() => undefined)
  }, waitMs).unref()
  return true
}

const waitsOnSteer = (session: ClaudeSession): boolean =>
  session.turnActive &&
  session.pendingSteers.length > 0 &&
  !session.retired &&
  !session.streamEnded &&
  !session.interruptRequested &&
  session.cancelInFlight === undefined

const interruptStep = async (session: ClaudeSession): Promise<boolean> => {
  session.stepInterrupted = true
  session.input.push({
    message: { content: INTERRUPTED_STEP_NOTE, role: "user" },
    parent_tool_use_id: null,
    priority: "next",
    session_id: session.sdkSessionId,
    type: "user"
  })
  await session.q.interrupt()
  return true
}
