import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"
import { plainFailureText } from "@codevisor/agent-runtime"

import { recordOf } from "./internal.js"
import type { ClaudeSession } from "./session.js"

type ResultMessage = SDKMessage & { type: "result" }

const MISSING_CONVERSATION = /no conversation found with session id/i

const STOPPED_DETAIL = "Claude Code stopped unexpectedly."

const RETIRED_DETAIL = "Claude Code was stopped before it could answer this message."

export const isStartupFailure = (session: ClaudeSession, message: ResultMessage): boolean =>
  message.is_error &&
  message.num_turns === 0 &&
  !session.turnActive &&
  session.pendingPrompt === undefined &&
  session.pendingUserCommands === 0

export const recordStartupFailure = (session: ClaudeSession, message: ResultMessage): void => {
  const errors = recordOf(message).errors
  const texts = Array.isArray(errors)
    ? errors.filter((error): error is string => typeof error === "string")
    : []
  session.startupFailure = texts.join("\n").trim() || STOPPED_DETAIL
}

export const startupError = (session: ClaudeSession, cause?: unknown): Error => {
  const failure = session.startupFailure ?? causeText(cause)
  const error = new Error(plainFailureText(failure) || STOPPED_DETAIL)
  if (!MISSING_CONVERSATION.test(failure)) return error
  return Object.assign(error, { conversationMissing: true })
}

export const retiredError = (): Error => new Error(RETIRED_DETAIL)

const causeText = (cause: unknown): string =>
  cause instanceof Error ? cause.message : STOPPED_DETAIL
