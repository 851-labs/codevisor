import type { Options as ClaudeOptions } from "@anthropic-ai/claude-agent-sdk"
import type { CreateSessionOptions, ToolGatewayConfig } from "@codevisor/agent-runtime"

import {
  adoptModelList,
  alignStartModel,
  applyClaudeModelFromProvider,
  claudeStartOptions,
  currentClaudeModelFor,
  metadataFor,
  resolveClaudeModel
} from "./models.js"
import type { ClaudeModel, ClaudeQuery, ClaudeSession } from "./session.js"
import { supersededSkillsOff } from "./skills.js"

export interface KnownClaudeModels {
  list: ReadonlyArray<ClaudeModel>
}

export type ConfigSelections = Readonly<Record<string, string>>

type ModelList = ReturnType<ClaudeQuery["supportedModels"]>

type ListedModels = Awaited<ModelList>

const DEFAULT_MODEL_LIST_TIMEOUT_MS = 3000

export const savedStartOptions = (
  saved: ConfigSelections,
  known: ReadonlyArray<ClaudeModel>,
  toolGateway: ToolGatewayConfig | undefined
): Pick<ClaudeOptions, "model" | "settings"> => {
  const model = savedModelChoice(saved, known)
  return claudeStartOptions({
    effort: saved.effort,
    model,
    speed: saved.speed,
    ...(toolGateway === undefined ? {} : { skillOverrides: supersededSkillsOff })
  })
}

export const modelsWithin = (
  modelList: ModelList,
  sessionOptions: CreateSessionOptions | undefined
): Promise<ListedModels | undefined> => {
  let timeout: ReturnType<typeof setTimeout> | undefined
  return Promise.race([
    modelList,
    new Promise<undefined>((resolve) => {
      timeout = setTimeout(
        () => resolve(undefined),
        sessionOptions?.modelListTimeoutMs ?? DEFAULT_MODEL_LIST_TIMEOUT_MS
      )
    })
  ]).finally(() => clearTimeout(timeout))
}

export const adoptListedModels = (
  session: ClaudeSession,
  models: ListedModels,
  known: KnownClaudeModels
): void => {
  adoptModelList(session, models)
  known.list = session.models
  currentClaudeModelFor(session)
}

export const adoptModelsWhenListed = (
  session: ClaudeSession,
  modelList: ModelList,
  known: KnownClaudeModels,
  startModel: string | undefined
): void => {
  modelList.then(
    (lateModels) => adoptLateModels(session, lateModels, known, startModel),
    () => undefined
  )
}

const savedModelChoice = (
  saved: ConfigSelections,
  known: ReadonlyArray<ClaudeModel>
): string | undefined => {
  if (saved.model === undefined) return saved.model
  if (known.length === 0) return saved.model

  return resolveClaudeModel(known, saved.model)?.value
}

const adoptLateModels = (
  session: ClaudeSession,
  models: ListedModels,
  known: KnownClaudeModels,
  startModel: string | undefined
): void => {
  if (lateModelsUnwanted(session)) return

  adoptModelList(session, models)
  known.list = session.models
  applyClaudeModelFromProvider(session, session.currentModel)
  void alignStartModel(session, startModel)
  emitModelOptions(session)
}

const lateModelsUnwanted = (session: ClaudeSession): boolean =>
  session.retired || session.models.length > 0

const emitModelOptions = (session: ClaudeSession): void => {
  void session.emit({
    kind: "session.updated",
    payload: {
      configId: "model",
      configOptions: metadataFor(session).configOptions,
      value: session.currentModel
    },
    subjectId: session.key
  })
}
