import type { RuntimeEvent } from "@codevisor/agent-runtime"
import type { SessionModeState } from "@codevisor/api"

export const askedQuestion = {
  questionId: "asked-question",
  questions: [
    {
      id: "db",
      question: "Which database?",
      options: [{ label: "Postgres" }, { label: "SQLite" }],
      allowsOther: true
    }
  ]
}

export const planApproval = {
  questionId: "plan-approval",
  questions: [
    {
      id: "exit_plan_mode",
      header: "Plan",
      question: "Ready to implement this plan?",
      options: [{ label: "Implement plan" }, { label: "Keep planning" }],
      allowsOther: false
    }
  ]
}

export type FakeQuestion = typeof askedQuestion

const questionsByPrompt: Readonly<Record<string, FakeQuestion>> = {
  "ask until cancelled": askedQuestion,
  "plan until cancelled": planApproval
}

export const questionAskedBy = (text: string): FakeQuestion | undefined => questionsByPrompt[text]

export const questionEvent = (
  sessionId: string,
  question: FakeQuestion,
  resolution?: { readonly outcome: string }
): RuntimeEvent => ({
  kind: "session.output",
  subjectId: sessionId,
  payload: {
    sessionUpdate: resolution === undefined ? "question" : "question_resolved",
    ...resolution,
    ...question
  }
})

const planModes: SessionModeState = {
  currentModeId: "plan",
  availableModes: [
    { id: "default", name: "Always Ask", canonicalId: "ask" },
    { id: "plan", name: "Plan", canonicalId: "plan" },
    { id: "bypassPermissions", name: "Bypass Permissions", canonicalId: "fullAccess" }
  ]
}

export const modesIn = (cwd: string): { readonly modes?: SessionModeState } =>
  cwd.includes("plan-modes") ? { modes: planModes } : {}
