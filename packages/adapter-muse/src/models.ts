import type { SessionConfigOption } from "@codevisor/api"

import type { ModelCatalogEntry } from "./protocol.js"

/// Muse's model catalog and reasoning tiers as Codevisor config options.

export const MODEL_OPTION_ID = "model"
export const EFFORT_OPTION_ID = "thought_level"

const tierNames: Record<string, string> = {
  none: "None",
  minimal: "Minimal",
  low: "Low",
  medium: "Medium",
  high: "High",
  xhigh: "Extra High",
  max: "Max",
  ultra: "Ultra"
}

/// The tiers a model accepts. Muse 1.4.7 lists them in `variants`;
/// `reasoningEffortVariants` is the described form newer catalogs fill.
export const modelTiers = (model: ModelCatalogEntry | undefined): ReadonlyArray<string> => {
  if (model === undefined) return []
  if (Array.isArray(model.variants) && model.variants.length > 0)
    return model.variants.filter((tier): tier is string => typeof tier === "string")
  return (model.reasoningEffortVariants ?? []).map((variant) => variant.tier)
}

/// The tier a session runs at when nobody chose one.
export const defaultTier = (model: ModelCatalogEntry | undefined): string | undefined => {
  const tiers = modelTiers(model)
  if (model?.defaultReasoningEffort !== undefined && tiers.includes(model.defaultReasoningEffort))
    return model.defaultReasoningEffort
  return tiers.includes("medium") ? "medium" : tiers[0]
}

export const configOptions = (state: {
  readonly models: ReadonlyArray<ModelCatalogEntry>
  readonly modelId: string | undefined
  readonly effort: string | undefined
}): Array<SessionConfigOption> => {
  const options: Array<SessionConfigOption> = []
  const current =
    state.models.find((model) => model.modelId === state.modelId) ??
    state.models.find((model) => model.isActive) ??
    state.models.find((model) => model.isDefault) ??
    state.models[0]
  if (current !== undefined)
    options.push({
      id: MODEL_OPTION_ID,
      name: "Model",
      category: "model",
      currentValue: current.modelId,
      options: state.models.map((model) => ({ value: model.modelId, name: model.displayLabel }))
    })
  const tiers = modelTiers(current)
  if (tiers.length > 0) {
    const effort =
      state.effort !== undefined && tiers.includes(state.effort)
        ? state.effort
        : defaultTier(current)
    options.push({
      id: EFFORT_OPTION_ID,
      name: "Reasoning",
      category: "thought_level",
      currentValue: effort!,
      options: tiers.map((tier) => ({ value: tier, name: tierNames[tier] ?? tier }))
    })
  }
  return options
}
