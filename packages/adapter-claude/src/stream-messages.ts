import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"

import { handleMessage } from "./messages.js"
import { applyClaudeModelFromProvider, emitModelFallback } from "./models.js"
import type { ClaudeSession } from "./session.js"
import { learnClaudeSkills } from "./skills.js"

type InitMessage = Extract<SDKMessage, { type: "system"; subtype: "init" }>

type RefusalFallbackMessage = Extract<
  SDKMessage,
  { type: "system"; subtype: "model_refusal_fallback" }
>

export const applyStreamMessage = (
  session: ClaudeSession,
  message: SDKMessage,
  readFile: (path: string) => string | undefined
): void => {
  if (isInitMessage(message)) {
    applyInitMessage(session, message)
    return
  }
  if (isLiveRefusalFallback(session, message)) {
    applyRefusalFallback(session, message)
    return
  }
  if (!session.retired) handleMessage(session, message, readFile)
}

const isInitMessage = (message: SDKMessage): message is InitMessage =>
  message.type === "system" && message.subtype === "init"

const isRefusalFallback = (message: SDKMessage): message is RefusalFallbackMessage =>
  message.type === "system" && message.subtype === "model_refusal_fallback"

const isLiveRefusalFallback = (
  session: ClaudeSession,
  message: SDKMessage
): message is RefusalFallbackMessage => !session.retired && isRefusalFallback(message)

const applyInitMessage = (session: ClaudeSession, message: InitMessage): void => {
  learnClaudeSkills(session, message)
  const expectedModel = session.currentModel
  applyClaudeModelFromProvider(session, message.model)
  adoptFastModeState(session, message)
  if (startModelFellBack(session, expectedModel)) {
    emitModelFallback(session, expectedModel, session.currentModel, null)
  }
}

const adoptFastModeState = (session: ClaudeSession, message: InitMessage): void => {
  if (message.fast_mode_state === undefined) return

  session.currentSpeed = message.fast_mode_state === "on" ? "fast" : "standard"
}

const startModelFellBack = (session: ClaudeSession, expectedModel: string): boolean =>
  !session.retired &&
  expectedModel.length > 0 &&
  session.models.length > 0 &&
  session.currentModel !== expectedModel

const applyRefusalFallback = (session: ClaudeSession, message: RefusalFallbackMessage): void => {
  const fallbackModel = applyClaudeModelFromProvider(session, message.fallback_model)
  emitModelFallback(
    session,
    message.original_model,
    fallbackModel,
    message.api_refusal_category ?? null
  )
}
