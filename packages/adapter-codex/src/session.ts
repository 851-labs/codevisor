import type { QuestionAnswer, RuntimeEmit } from "@codevisor/agent-runtime"
import type { QuestionSpec, SessionContext, SessionGoal, TurnStopKind } from "@codevisor/api"

import type { CodexClient } from "./client.js"
import type { CodexSkill } from "./skills.js"
import type { CodexTitleGenerator } from "./title-generation.js"

export interface CodexModel {
  readonly value: string
  readonly name: string
  readonly efforts: ReadonlyArray<string>
  readonly defaultEffort: string
  readonly supportsFast: boolean
  readonly defaultsToFast: boolean
}

export interface PendingCodexQuestion {
  readonly questions: ReadonlyArray<QuestionSpec>
  readonly resolve: (response: unknown) => void
  readonly reject: (error: Error) => void
  readonly timer: NodeJS.Timeout | undefined
  readonly respond: (answers: NonNullable<QuestionAnswer["answers"]>) => unknown
  readonly cancelResponse?: unknown
}

export interface CodexSession {
  readonly key: string
  readonly threadId: string
  readonly client: CodexClient
  readonly emit: RuntimeEmit
  readonly cwd: string
  activeTurnId: string | undefined
  pendingTurnError: { message: string; retryable: boolean; stopKind?: TurnStopKind } | undefined
  pendingPrompt: { resolve: (value: { stopReason: string }) => void } | undefined
  interruptRequested: boolean
  lastHarnessTitle: string | undefined
  titleGenerator?: CodexTitleGenerator
  currentModel: string
  currentEffort: string | undefined
  reasoningSummariesRejected?: boolean
  currentSpeed: "standard" | "fast" | undefined
  currentModeId: string
  collaborationEngaged: boolean
  models: ReadonlyArray<CodexModel>
  skills: ReadonlyArray<CodexSkill> | undefined
  readonly itemKinds: Map<string, string>
  readonly messagePhases: Map<string, "commentary" | "final">
  readonly collabThreads: Map<string, string>
  readonly collabRunTurns: Map<string, string>
  readonly itemTitles: Map<string, string>
  lastEmittedGoal: SessionGoal | undefined
  lastGoalEmitAtMs: number
  pendingGoalSnapshot: SessionGoal | undefined
  readonly pendingQuestions: Map<string, PendingCodexQuestion>
  latestContext: SessionContext | undefined
}
