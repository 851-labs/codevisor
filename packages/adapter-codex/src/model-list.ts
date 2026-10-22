import { isRecord } from "./internal.js"
import { CODEX_FAST_TIER } from "./models.js"
import type { CodexModel } from "./session.js"

export const codexModelsFrom = (modelList: unknown): ReadonlyArray<CodexModel> => {
  const listed = isRecord(modelList) && Array.isArray(modelList.data) ? modelList.data : []
  return listed.flatMap(listedModel)
}

const listedModel = (model: unknown): Array<CodexModel> => {
  if (!isRecord(model)) return []
  if (model.hidden === true) return []

  const value = typeof model.model === "string" ? model.model : undefined
  if (value === undefined) return []

  const efforts = reasoningEfforts(model)
  const tiers = serviceTiers(model)
  return [
    {
      defaultEffort:
        typeof model.defaultReasoningEffort === "string" ? model.defaultReasoningEffort : "medium",
      defaultsToFast: model.defaultServiceTier === CODEX_FAST_TIER,
      efforts,
      name: typeof model.displayName === "string" ? model.displayName : value,
      supportsFast: tiers.includes(CODEX_FAST_TIER),
      value
    }
  ]
}

const reasoningEfforts = (model: Record<string, unknown>): Array<string> => {
  if (!Array.isArray(model.supportedReasoningEfforts)) return []

  return model.supportedReasoningEfforts.flatMap(effortName)
}

const effortName = (option: unknown): Array<string> =>
  isRecord(option) && typeof option.reasoningEffort === "string" ? [option.reasoningEffort] : []

const serviceTiers = (model: Record<string, unknown>): Array<string> => {
  if (!Array.isArray(model.serviceTiers)) return []

  return model.serviceTiers.flatMap(tierId)
}

const tierId = (tier: unknown): Array<string> =>
  isRecord(tier) && typeof tier.id === "string" ? [tier.id] : []
