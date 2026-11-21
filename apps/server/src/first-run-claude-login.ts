import { FirstRunClaudeCodeLogin, type FirstRunHarness } from "@codevisor/api"
import { Schema } from "effect"

import { run, type CodevisorServerServices } from "./server-context.js"

export const holdClaudeCodeLoginQuestion = async (
  services: CodevisorServerServices,
  harnesses: ReadonlyArray<FirstRunHarness>
): Promise<void> => {
  if (!harnesses.some((harness) => harness.id === claudeCode)) return
  if ((await storedQuestion(services)) !== undefined) return

  const offer = await services.sharedAccounts?.claudeCodeTransferOffer().catch(() => undefined)
  if (offer === undefined) return

  const question: FirstRunClaudeCodeLogin = offer.email === undefined ? {} : { email: offer.email }
  await run(services.db.setMachineSetting(questionSetting, JSON.stringify(question)))
}

export const readClaudeCodeLoginQuestion = async (
  services: CodevisorServerServices
): Promise<FirstRunClaudeCodeLogin | undefined> => {
  const stored = await storedQuestion(services)
  if (stored === undefined || stored === answered) return undefined

  return decodeQuestion(stored)
}

export const settleClaudeCodeLoginQuestion = (services: CodevisorServerServices): Promise<void> =>
  run(services.db.setMachineSetting(questionSetting, answered))

const claudeCode = "claude-code"

const questionSetting = "first-run-claude-code-login"

const answered = "answered"

const storedQuestion = (services: CodevisorServerServices): Promise<string | undefined> =>
  run(services.db.getMachineSetting(questionSetting))

const decodeStored = Schema.decodeUnknownOption(FirstRunClaudeCodeLogin)

const decodeQuestion = (stored: string): FirstRunClaudeCodeLogin | undefined => {
  try {
    const decoded = decodeStored(JSON.parse(stored))
    return decoded._tag === "Some" ? decoded.value : undefined
  } catch {
    return undefined
  }
}
