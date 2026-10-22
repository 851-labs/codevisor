import { randomUUID } from "node:crypto"

import {
  answersIfDefined,
  questionIdFirstPayloads,
  type QuestionAnswer,
  type RuntimeEvent
} from "@codevisor/agent-runtime"
import type { QuestionSpec } from "@codevisor/api"

import { record, type JsonRecord } from "./internal.js"
import { canonicalToolName, filePath, stringValue } from "./tool-updates.js"
import { prefixChildTitle, type ChildSession, type TrackedTool } from "./translate.js"

const questionPayloads = questionIdFirstPayloads(answersIfDefined)

export type PermissionDecision = "once" | "always" | "reject"

const DECISIONS: ReadonlyArray<readonly [string, PermissionDecision]> = [
  ["Allow once", "once"],
  ["Always allow", "always"],
  ["Reject", "reject"]
]

interface PendingQuestion {
  readonly requestID: string
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly settle: (decision: PermissionDecision | undefined) => void
}

const permissionTitle = (toolName: string, input: JsonRecord): string | undefined => {
  switch (canonicalToolName(toolName)) {
    case "external_directory":
      return (
        stringValue(input.description) ?? stringValue(input.command) ?? stringValue(input.parentDir)
      )
    case "webfetch":
      return stringValue(input.url)
    case "websearch":
      return stringValue(input.query)
    case "grep":
    case "glob":
      return stringValue(input.pattern)
    case "read":
    case "edit":
    case "write":
    case "patch":
      return filePath(input)
    case "shell":
      return stringValue(input.command) ?? stringValue(input.cmd)
    default:
      return undefined
  }
}

export const permissionQuestion = (
  request: JsonRecord,
  tool: TrackedTool | undefined,
  child: ChildSession | undefined
): QuestionSpec => {
  const toolName = tool?.name ?? stringValue(request.action) ?? "tool"
  const input = tool?.input ?? record(request.metadata) ?? {}
  const title = permissionTitle(toolName, input) ?? stringValue(request.message)
  const question =
    title === undefined || title === ""
      ? (child?.title ?? "Allow the agent to proceed?")
      : prefixChildTitle(child, `${toolName}: ${title}`)
  return {
    allowsOther: false,
    id: "permission",
    options: DECISIONS.map(([label]) => ({ label })),
    question
  }
}

export const makePermissionQuestions = (emit: (event: RuntimeEvent) => void, sessionId: string) => {
  const pending = new Map<string, PendingQuestion>()

  const resolved = (
    questionId: string,
    entry: PendingQuestion,
    outcome: "answered" | "cancelled",
    answers?: QuestionAnswer["answers"]
  ) =>
    emit({
      kind: "session.output",
      subjectId: sessionId,
      payload: questionPayloads.resolved(questionId, entry.questions, {
        outcome,
        answers
      })
    })

  return {
    ask: (spec: QuestionSpec, requestID: string): Promise<PermissionDecision | undefined> => {
      const questionId = randomUUID()
      emit({
        kind: "session.output",
        subjectId: sessionId,
        payload: questionPayloads.asked(questionId, [spec])
      })
      return new Promise((settle) => {
        pending.set(questionId, { requestID, questions: [spec], settle })
      })
    },
    answer: (questionId: string, answer: QuestionAnswer): void => {
      const entry = pending.get(questionId)
      if (entry === undefined) throw new Error(`No pending question: ${questionId}`)
      pending.delete(questionId)
      const label = Object.values(answer.answers ?? {}).flatMap((value) => [...value.answers])[0]
      const decision =
        answer.outcome === "answered"
          ? DECISIONS.find(([candidate]) => candidate === label)?.[1]
          : undefined
      entry.settle(decision ?? "reject")
      resolved(
        questionId,
        entry,
        answer.outcome === "answered" ? "answered" : "cancelled",
        answer.outcome === "answered" ? answer.answers : undefined
      )
    },
    settled: (requestID: string): void => {
      for (const [questionId, entry] of pending) {
        if (entry.requestID !== requestID) continue
        pending.delete(questionId)
        entry.settle(undefined)
        resolved(questionId, entry, "cancelled")
      }
    },
    cancelAll: (): void => {
      for (const [questionId, entry] of pending) {
        pending.delete(questionId)
        entry.settle("reject")
        resolved(questionId, entry, "cancelled")
      }
    }
  }
}
