import type { FirstRunClaudeCodeLoginAnswer } from "@codevisor/api"

import {
  readClaudeCodeLoginQuestion,
  settleClaudeCodeLoginQuestion
} from "./first-run-claude-login.js"
import { publishFirstRunStatus, readFirstRunStatus } from "./first-run-status.js"
import { HttpFailure, type CodevisorServerServices, type EventFanout } from "./server-context.js"

export type ClaudeCodeLoginChoice = FirstRunClaudeCodeLoginAnswer["choice"]

export const answerClaudeCodeLogin = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  choice: ClaudeCodeLoginChoice
): Promise<void> => {
  if ((await readClaudeCodeLoginQuestion(services)) === undefined) throw notAsking()
  if (choice === "transfer") await transfer(services)

  await settleClaudeCodeLoginQuestion(services)
  await publishFirstRunStatus(services, fanout, await readFirstRunStatus(services))
}

const transfer = async (services: CodevisorServerServices): Promise<void> => {
  const transferred = await services.sharedAccounts?.transferClaudeCodeLogin()
  if (transferred !== true) throw notTransferred()
}

const notAsking = (): HttpFailure =>
  new HttpFailure(404, "Claude Code's sign-in isn't waiting for an answer")

const notTransferred = (): HttpFailure =>
  new HttpFailure(409, "Claude Code's sign-in couldn't be moved. Sign in to Claude instead.")
