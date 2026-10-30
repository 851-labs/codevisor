import type { QuestionPresentation } from "@codevisor/api"

import { jsonRecord, type JsonRecord } from "./event-payloads.js"

const setupPresentations: ReadonlySet<unknown> = new Set<QuestionPresentation>([
  "browserExtensionSetup",
  "browserExtensionWaiting",
  "browserExtensionUpdate",
  "computerUsePermissions"
])

const isSetupPresentation = (value: unknown): value is QuestionPresentation =>
  setupPresentations.has(value)

export const setupQuestionPresentation = (
  payload: JsonRecord | undefined
): QuestionPresentation | undefined => {
  const questions = payload?.questions
  return (Array.isArray(questions) ? questions : [])
    .map((question) => jsonRecord(question)?.presentation)
    .find(isSetupPresentation)
}

const waitsOnPluginSetup = (payload: JsonRecord | undefined): boolean => {
  const questions = payload?.questions
  return (Array.isArray(questions) ? questions : []).some(
    (question) => jsonRecord(question)?.presentation === "pluginSetup"
  )
}

export const isAgentQuestion = (payload: JsonRecord | undefined): boolean =>
  setupQuestionPresentation(payload) === undefined && !waitsOnPluginSetup(payload)
