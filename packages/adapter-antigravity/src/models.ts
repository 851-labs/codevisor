import type { SessionConfigOption } from "@codevisor/api"

export const MODEL_OPTION_ID = "model"
export const EFFORT_OPTION_ID = "thought_level"

export interface AgyModelVariant {
  readonly slug: string
  readonly tier: string | undefined
  readonly label: string | undefined
}

export interface AgyModel {
  readonly id: string
  readonly name: string
  readonly variants: ReadonlyArray<AgyModelVariant>
}

const LINE = /^([A-Za-z0-9][\w.-]*)(?:\t|\s{2,})\s*(\S.*?)\s*$/
const TIERED = /^(.*\S)\s+\(([^()]+)\)$/

export const parseModels = (output: string): Array<AgyModel> => {
  const models: Array<{ id: string; name: string; variants: Array<AgyModelVariant> }> = []
  for (const line of output.split("\n")) {
    const listed = LINE.exec(line.trim())
    if (listed === null) continue
    const [, slug = "", display = ""] = listed
    const tiered = TIERED.exec(display)
    const label = tiered?.[2]
    const tier = label?.toLowerCase().replace(/\s+/g, "-")
    const id =
      tier !== undefined && slug.toLowerCase().endsWith(`-${tier}`)
        ? slug.slice(0, -(tier.length + 1))
        : slug
    const name = tiered?.[1] ?? display
    const existing = models.find((model) => model.id === id)
    const variant = { slug, tier, label }
    if (existing === undefined) models.push({ id, name, variants: [variant] })
    else existing.variants.push(variant)
  }
  return models
}

export const defaultTier = (model: AgyModel): string | undefined => {
  const tiers = model.variants.map((variant) => variant.tier)
  return tiers.includes("medium") ? "medium" : tiers[0]
}

export const resolveSelection = (
  models: ReadonlyArray<AgyModel>,
  selection: { readonly modelId?: string | undefined; readonly tier?: string | undefined }
): { readonly model: AgyModel; readonly variant: AgyModelVariant } | undefined => {
  const model = models.find((entry) => entry.id === selection.modelId) ?? models[0]
  if (model === undefined) return undefined
  const variant =
    model.variants.find((entry) => entry.tier === selection.tier) ??
    model.variants.find((entry) => entry.tier === defaultTier(model))!
  return { model, variant }
}

export const configOptions = (
  models: ReadonlyArray<AgyModel>,
  selection: { readonly modelId?: string | undefined; readonly tier?: string | undefined }
): Array<SessionConfigOption> => {
  const resolved = resolveSelection(models, selection)
  if (resolved === undefined) return []
  const options: Array<SessionConfigOption> = [
    {
      id: MODEL_OPTION_ID,
      name: "Model",
      category: "model",
      currentValue: resolved.model.id,
      options: models.map((model) => ({ value: model.id, name: model.name }))
    }
  ]
  const tiers = resolved.model.variants.filter((variant) => variant.tier !== undefined)
  if (tiers.length > 1)
    options.push({
      id: EFFORT_OPTION_ID,
      name: "Reasoning",
      category: "thought_level",
      currentValue: resolved.variant.tier!,
      options: tiers.map((variant) => ({ value: variant.tier!, name: variant.label! }))
    })
  return options
}
